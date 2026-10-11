Bundled offline document renderer assets:

- markdown-it 14.1.0 (npm distribution), MIT license in markdown-it.LICENSE.
- Prism 1.29.0 (npm distribution), MIT license in Prism.LICENSE.
- Prism components: core, markup, CSS, clike, JavaScript, TypeScript, JSX,
  TSX, Python, Rust, Bash, JSON, Swift, YAML, in dependency order.

parser.js adapts markdown-it for JavaScriptCore. reader.js controls the
read-only WKWebView. Neither project HTML nor project scripts are executed.
Local images are served by DocumentAssetHandler after project containment
and bounded regular-file checks. No CDN or runtime network dependency.
