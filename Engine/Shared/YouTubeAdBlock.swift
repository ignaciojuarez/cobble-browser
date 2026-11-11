import Foundation

/// Built-in YouTube ad blocking for both engines, part of a profile's content blocking.
/// Network rules cannot see in-video ads: the player learns about them from fields in its own
/// first-party JSON. This page-world script removes those fields before YouTube reads them,
/// recovers from the playback stall YouTube imposes when planned ads do not play, and hides
/// the site's ad slots. It ports uBlock Origin's current YouTube filters (GPL-3.0); see
/// THIRD_PARTY_NOTICES.md. Expect to refresh it when YouTube changes.
enum YouTubeAdBlock {
    /// Chromium match patterns; `*.` also matches the bare domain.
    static let matches = ["*://*.youtube.com/*", "*://*.youtube-nocookie.com/*", "*://*.youtubekids.com/*"]
    /// Origins Chromium's withheld host access must grant before its content script runs.
    static let origins = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "tv.youtube.com",
                          "www.youtube-nocookie.com", "youtubekids.com", "www.youtubekids.com"]
        .map { URL(string: "https://\($0)/")! }

    /// `exceptions` are canonical top-level origins allowed through the blocker.
    static func script(exceptions: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: exceptions)) ?? Data("[]".utf8)
        return source.replacingOccurrences(of: "__COBBLE_EXCEPTIONS__", with: String(decoding: data, as: UTF8.self))
    }

    private static let source = #"""
    (() => {
    'use strict';
    // Player hosts only; Studio and account pages are left alone.
    if (!/^((www|m|music|tv)\.)?youtube\.com$|^(www\.)?youtube-nocookie\.com$|^(www\.)?youtubekids\.com$/.test(location.hostname)) return;
    const ancestors = location.ancestorOrigins;
    if (__COBBLE_EXCEPTIONS__.includes(ancestors?.length ? ancestors[ancestors.length - 1] : location.origin)) return;

    const hook = (owner, name, apply) => {
        const original = owner[name];
        if (typeof original === 'function') owner[name] = new Proxy(original, { apply });
    };
    const safely = (value, body) => { try { body(value); } catch (_) {} return value; };

    // 1. Remove ads from player, watch, Shorts and navigation responses.
    const strip = object => {
        let changed = false;
        if (object && typeof object === 'object') {
            for (const key of ['adPlacements', 'adSlots', 'playerAds']) if (key in object) { delete object[key]; changed = true; }
        }
        return changed;
    };
    const dropAdEntries = object => {
        const entries = object?.entries;
        if (!Array.isArray(entries)) return false;
        const kept = entries.filter(entry => !entry?.command?.reelWatchEndpoint?.adClientParams?.isAd);
        if (kept.length === entries.length) return false;
        entries.splice(0, entries.length, ...kept);
        return true;
    };
    const pruneObject = object => [
        strip(object), strip(object.playerResponse),
        strip(object.endpoint?.watchEndpoint?.unserializedPrefetchData?.playerResponse),
        dropAdEntries(object), dropAdEntries(object.reelWatchSequenceResponse)
    ].includes(true);
    // get_watch returns an array of parts.
    const prune = value => !value || typeof value !== 'object' ? false
        : !Array.isArray(value) ? pruneObject(value)
        : value.map(item => item && typeof item === 'object' && !Array.isArray(item) && pruneObject(item)).includes(true);

    hook(JSON, 'parse', (target, self, args) => safely(Reflect.apply(target, self, args), prune));
    // `Response.json()` parses natively, bypassing JSON.parse.
    const adEndpoint = /\/(player|get_watch|reel_watch_sequence|resolve_url)(\?|$)|\/playlist\?/;
    hook(Response.prototype, 'json', (target, self, args) => {
        const result = Reflect.apply(target, self, args);
        let url = '';
        try { url = self.url; } catch (_) {}
        return adEndpoint.test(url) ? result.then(value => safely(value, prune)) : result;
    });
    // A watch page loaded directly embeds its player response in an inline script.
    for (const name of ['ytInitialPlayerResponse', 'playerResponse']) {
        let stored;
        try {
            Object.defineProperty(window, name, { configurable: true, get: () => stored, set: value => { stored = safely(value, prune); } });
        } catch (_) {}
    }
    // YouTube can read unhooked functions from a fresh same-origin frame; give it these instead.
    const parse = JSON.parse, json = Response.prototype.json;
    hook(Node.prototype, 'appendChild', (target, self, args) => {
        const result = Reflect.apply(target, self, args);
        if (args[0]?.tagName === 'IFRAME') {
            try {
                const frame = args[0].contentWindow;
                if (frame?.location.href === 'about:blank') { frame.JSON.parse = parse; frame.Response.prototype.json = json; }
            } catch (_) {}
        }
        return result;
    });

    // 2. When ads are removed, YouTube's server withholds the video for about the ads' length. On
    // that stall, reload the video while describing the request as a context that has no ads,
    // trying the next description if YouTube rejects one.
    // uBlock Origin applies this only on www.youtube.com.
    const recoverStalls = () => {
        // Shorten the 17-second native timer YouTube uses for its ad wait.
        hook(window, 'setTimeout', (target, self, args) => {
            if (args[1] === 17000 && typeof args[0] === 'function' && String(args[0]).includes('[native code]')) args[1] = 17;
            return Reflect.apply(target, self, args);
        });
        const descriptions = ['channel', 'lactmilli', 'yahi', 'inline'];
        let remaining = descriptions, flagged = false, originalAgent;
        const setDescription = name => {
            const client = window.ytcfg?.data_?.INNERTUBE_CONTEXT?.client;
            if (!client) return;
            if (originalAgent === undefined) originalAgent = client.userAgent;
            const prefix = typeof originalAgent === 'string' && originalAgent.match(/Mozilla\/5\.0 \([^)]+/)?.[0];
            client.userAgent = name && prefix ? originalAgent.replace(prefix, `${prefix}; ${name}`) : originalAgent;
        };
        const described = /; (adunit|channel|lactmilli|inline|yahi|eafg|yaf4)\b/;
        hook(JSON, 'stringify', (target, self, args) => {
            const body = args[0];
            try {
                const client = body?.context?.client, agent = String(client?.userAgent ?? '');
                if (body?.attestationRequest && client && described.test(agent)) {
                    const playback = body.playbackContext?.contentPlaybackContext;
                    if (agent.includes('channel') && client.clientName === 'WEB') client.clientScreen = 'CHANNEL';
                    if (agent.includes('lactmilli')) body.params = '8AUB';
                    if (agent.includes('yahi')) body.params = 'YAHI';
                    if (playback) {
                        if (agent.includes('inline')) playback.isInlinePlaybackNoAd = true;
                        if (/channel|lactmilli|inline/.test(agent)) playback.lactMilliseconds = String(Date.now());
                        playback.referer = String(playback.referer ?? '').replace(/(?:#reloadxhr)?$/, '#reloadxhr');
                    }
                }
                if (body?.createCommentParams && typeof client?.userAgent === 'string') client.userAgent = client.userAgent.replace(described, '');
            } catch (_) {}
            return Reflect.apply(target, self, args);
        });
        const read = () => {
            const player = document.getElementById('movie_player'), state = { player };
            try { state.response = player.getPlayerResponse(); } catch (_) {}
            try { state.stats = player.getStatsForNerds(); } catch (_) {}
            try { state.progress = player.getProgressState(); } catch (_) {}
            try { state.buffering = player.getPlayerStateObject().isBuffering; } catch (_) {}
            return state;
        };
        const stalled = ({ stats, buffering }) => buffering && stats?.buffer_health_seconds === '0.00 s' && stats?.resolution === '0x0' && remaining.length > 0;
        // YouTube's stall arrives as a 104- or 105-byte message, or as its interruption notice.
        const signal = () => {
            const state = read();
            if (!state.player || !stalled(state)) return;
            // A reload that stalls again rejected the current description.
            if (state.response?.playbackTracking?.videostatsPlaybackUrl?.baseUrl?.includes('reloadxhr')) remaining = remaining.slice(1);
            flagged = true;
        };
        hook(Map.prototype, 'has', (target, self, args) => {
            if (args[0] === 'onSnackbarMessage' && !flagged) signal();
            return Reflect.apply(target, self, args);
        });
        hook(Array.prototype, 'push', (target, self, args) => {
            const bytes = args[0];
            if (bytes instanceof Uint8Array && (bytes.length === 104 || bytes.length === 105) && bytes.buffer.byteLength === bytes.length) signal();
            return Reflect.apply(target, self, args);
        });
        hook(Promise.prototype, 'then', (target, self, args) => {
            if (typeof args[0] === 'function' && String(args[0]).includes('onAbnormalityDetected')) args[0] = () => {};
            return Reflect.apply(target, self, args);
        });
        const premium = () => window.ytInitialData?.topbar?.desktopTopbarRenderer?.logo?.topbarLogoRenderer?.iconImage?.iconType === 'YOUTUBE_PREMIUM_LOGO'
            || document.getElementById('masthead')?.getAttribute('logo-type') === 'YOUTUBE_PREMIUM_LOGO';
        const check = () => {
            const state = read(), { player, response, stats, progress } = state;
            if (!player || !/\/watch\?|\/embed\//.test(location.href)) { remaining = descriptions; return; }
            if (premium() || location.href.startsWith('https://www.youtube.com/tv#/')) return;
            if (!(progress?.duration > 0 && (progress.loaded < progress.duration || progress.duration - progress.current > 1)) && !response?.videoDetails?.isLive) return;
            if (!stats) return;
            // A server-inserted ad is playing: move past it.
            if (String(stats.debug_info).startsWith('SSAP, AD')) { if (progress?.duration > 0) player.seekTo?.(progress.duration); return; }
            const video = response?.videoDetails?.videoId;
            const start = response?.playerConfig?.playbackStartConfig?.startSeconds || parseInt(new URLSearchParams(location.search).get('t'), 10) || 0;
            const error = response?.playabilityStatus?.errorScreen;
            const reason = JSON.stringify(error?.playerErrorMessageRenderer?.subreason?.runs
                || error?.playerInterstitialRenderer?.content?.interstitialViewModel?.description?.commandRuns) ?? '';
            if (response?.playabilityStatus?.status === 'UNPLAYABLE' && !error?.playerErrorMessageRenderer?.playerCaptchaViewModel
                && reason.includes('WEB_PAGE_TYPE_UNKNOWN') && reason.includes('https://support.google.com/youtube/answer/3037019')) {
                remaining = remaining.slice(1);
                setDescription(remaining[0] ?? '');
                flagged = false;
                player.loadVideoById(video, start);
            } else if (remaining.length === 0) {
                flagged = false;
                setDescription('');
            } else if (flagged && stalled(state)) {
                setDescription(remaining[0]);
                flagged = false;
                player.loadVideoById(video, start);
            } else if (!flagged && progress.current - start > 0.1 && progress.current - start < 5 && location.href.includes('&list=') && player.getPlaylistId?.() === null) {
                // Reloading drops the playlist; restore it.
                const manager = document.querySelector('yt-playlist-manager'), playlist = manager?.getPlaylistData?.();
                if (playlist) { manager.setPlaylistData?.(playlist); manager.setPlayerPlaybackControlData?.({ playlistPanelRenderer: playlist }); }
            }
        };
        if (window === window.top || /\/embed\//.test(location.pathname)) setInterval(() => { try { check(); } catch (_) {} }, 500);
    };
    if (location.hostname === 'www.youtube.com') recoverStalls();

    // 3. Hide the site's ad slots.
    const style = document.createElement('style');
    style.textContent = [
        '#masthead-ad', 'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer',
        'ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer)', 'ytd-rich-item-renderer:has(> ytd-ad-slot-renderer)',
        'ytd-rich-section-renderer:has(ytd-ad-slot-renderer)', 'ytd-search-pyv-renderer', 'ytd-promoted-sparkles-web-renderer',
        'ytd-promoted-video-renderer', 'ytd-compact-promoted-video-renderer', 'ytd-display-ad-renderer',
        'ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"]',
        'ytd-reel-video-renderer:has(ytd-ad-slot-renderer)', '.ytp-ad-overlay-container', '.ytp-suggested-action-badge',
        'ad-slot-renderer', 'ytm-companion-ad-renderer', 'ytm-promoted-sparkles-web-renderer'
    ].join(',\n') + ' { display: none !important; }';
    const attach = () => (document.head || document.documentElement).appendChild(style);
    if (document.documentElement) attach();
    else new MutationObserver((_, observer) => { if (document.documentElement) { observer.disconnect(); attach(); } })
        .observe(document, { childList: true });
    })();
    """#
}
