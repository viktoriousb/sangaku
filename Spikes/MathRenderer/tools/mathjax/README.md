# MathJax bundle for JavaScriptCore

`entry.js` is bundled into `Sources/RendererSpike/Resources/mathjax/mathjax-stix2.js` with
@mathjax/src 4.1.3, @mathjax/mathjax-stix2-font 4.1.3 and esbuild 0.28.2:

    npm install --ignore-scripts @mathjax/src@4.1.3 @mathjax/mathjax-stix2-font@4.1.3 esbuild@0.28.2
    ls node_modules/@mathjax/mathjax-stix2-font/mjs/svg/dynamic/*.js | sed 's#.*/dynamic/##' \
      | sed "s#^#import '@mathjax/mathjax-stix2-font/mjs/svg/dynamic/#; s#\$#';#" > stix2-dynamic.js
    NODE_PATH=node_modules esbuild entry.js --bundle --format=iife --platform=neutral --target=es2020 \
      --minify --main-fields=module,main --outfile=mathjax-stix2.js
