// rr2fix: adapts the game's 2011 phone controller page to current browsers.
// rr2fix inserts this before the page's own scripts. The game's files are not modified.
(function () {
    var iOS = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
              (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

    // The page connects with ws://, which a secure page isn't allowed to open.
    var NativeWebSocket = window.WebSocket;
    window.WebSocket = function (url, protocols) {
        if (location.protocol === 'https:') url = String(url).replace(/^ws:/, 'wss:');
        return protocols === undefined ? new NativeWebSocket(url) : new NativeWebSocket(url, protocols);
    };
    window.WebSocket.prototype = NativeWebSocket.prototype;

    // The game picks the steering axis from window.orientation (0, 90, -90 or 180),
    // which some browsers no longer have.
    if (typeof window.orientation !== 'number' && screen.orientation) {
        Object.defineProperty(window, 'orientation', {
            get: function () { var a = screen.orientation.angle; return a === 270 ? -90 : a; }
        });
        screen.orientation.addEventListener('change', function () {
            window.dispatchEvent(new Event('orientationchange'));
        });
    }

    // The game expects gravity the way iOS reports it. Other browsers report every axis
    // with the opposite sign. Add ?flip to the address if steering is reversed anyway.
    var sign = iOS ? 1 : -1;
    if (/[?&]flip\b/.test(location.search)) sign = -sign;

    var nativeAddEventListener = window.addEventListener;
    window.addEventListener = function (type, listener, options) {
        if (type === 'devicemotion' && typeof listener === 'function') {
            var inner = listener;
            listener = function (event) {
                var g = event.accelerationIncludingGravity;
                if (!g || g.x === null) return;
                inner.call(this, {accelerationIncludingGravity: {x: sign * g.x, y: sign * g.y, z: sign * g.z}});
            };
        }
        return nativeAddEventListener.call(window, type, listener, options);
    };

    // Stop the phone sleeping while you only tilt it.
    var wakeLock = null;
    function keepAwake() {
        if (!navigator.wakeLock || wakeLock || document.visibilityState !== 'visible') return;
        navigator.wakeLock.request('screen').then(function (lock) {
            wakeLock = lock;
            lock.addEventListener('release', function () { wakeLock = null; });
        }, function () {});
    }
    document.addEventListener('visibilitychange', keepAwake);
    nativeAddEventListener.call(window, 'touchend', keepAwake, true);

    // iOS only sends motion events after the user allows it, from a tap.
    document.addEventListener('DOMContentLoaded', function () {
        keepAwake();
        if (!window.DeviceMotionEvent || typeof DeviceMotionEvent.requestPermission !== 'function') return;
        var overlay = document.createElement('div');
        overlay.textContent = 'Tap to turn on tilt steering';
        overlay.style.cssText = 'position:fixed;left:0;top:0;right:0;bottom:0;z-index:1000;display:flex;' +
            'align-items:center;justify-content:center;text-align:center;padding:20px;' +
            'background:rgba(0,0,0,0.85);color:#fff;font:bold 22px -apple-system,Helvetica,sans-serif;';
        // Keep these taps away from the page's handlers, which forward touches to the game.
        function swallow(e) { e.stopPropagation(); e.preventDefault(); }
        overlay.addEventListener('touchstart', swallow);
        overlay.addEventListener('touchmove', swallow);
        overlay.addEventListener('touchend', function (e) {
            swallow(e);
            DeviceMotionEvent.requestPermission().then(function (state) {
                if (state === 'granted') overlay.parentNode.removeChild(overlay);
                else overlay.textContent = 'Motion access was denied. Close this tab, open the page again and tap Allow.';
            }, function (err) {
                overlay.textContent = 'Could not turn on motion: ' + err;
            });
        });
        document.body.appendChild(overlay);
    });
})();
