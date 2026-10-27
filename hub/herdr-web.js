// Browser-side glue for herdr in ttyd, injected into ttyd's own page by
// hub/herdr-web-index. ttyd's terminal (xterm.js) on its own:
//   - ignores OSC 52, which is how herdr copies a selection to the clipboard;
//   - lets the browser's context menu cover herdr's right-click menu;
//   - sends ctrl+v to the pane as ^V instead of pasting (Windows, Linux).
// This fixes all three, for each terminal ttyd creates (window.term).
(function () {
  'use strict';
  var isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

  // The page is only ever served from localhost (port-forward) or over HTTPS
  // (behind the sign-in proxy), so the async clipboard API is there.
  function copy(text) {
    if (!navigator.clipboard) return;
    navigator.clipboard.writeText(text).catch(function (e) { console.warn('herdr: copy failed', e); });
  }

  // OSC 52: "<targets>;<base64>". "?" asks to read the clipboard; a browser
  // page can't answer that without a prompt, so it is ignored.
  function onOsc52(data) {
    var i = data.indexOf(';');
    var payload = i < 0 ? data : data.slice(i + 1);
    if (payload === '?' || payload === '') return true;
    try {
      var bytes = atob(payload);
      var text = new TextDecoder().decode(Uint8Array.from(bytes, function (c) { return c.charCodeAt(0); }));
      copy(text);
    } catch (e) { /* not base64: ignore */ }
    return true;
  }

  function attach(term) {
    if (term.__herdrWeb) return;
    term.__herdrWeb = true;
    term.parser.registerOscHandler(52, onOsc52);
  }

  // ttyd creates its terminal after this script runs, and may create a new
  // one when it reconnects.
  setInterval(function () { if (window.term && window.term.parser) attach(window.term); }, 250);

  // herdr has its own right-click menus; keep the browser's out of the way.
  document.addEventListener('contextmenu', function (e) {
    if (e.target.closest && e.target.closest('.xterm')) e.preventDefault();
  }, true);

  // ctrl+v pastes, as in other web terminals. Stopping the key here keeps
  // xterm.js from turning it into ^V, so the browser's paste goes ahead and
  // xterm.js sends it to herdr as a bracketed paste. (macOS: cmd+v already
  // pastes, and ctrl+v stays ^V.) ctrl+shift+v works everywhere.
  window.addEventListener('keydown', function (e) {
    if (!isMac && e.ctrlKey && !e.altKey && !e.metaKey && (e.key === 'v' || e.key === 'V') &&
        e.target.closest && e.target.closest('.xterm')) {
      e.stopImmediatePropagation();
    }
  }, true);
})();
