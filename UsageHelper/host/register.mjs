import { registerHooks, stripTypeScriptTypes } from 'node:module';
import { readFileSync } from 'node:fs';

const vendor = new URL('../vendor/orca/', import.meta.url).href;
registerHooks({
  load(url, context, nextLoad) {
    if (url.startsWith(vendor) && url.endsWith('.ts')) {
      const source = stripTypeScriptTypes(readFileSync(new URL(url), 'utf8'),
        { mode: 'transform', sourceUrl: url });
      const commonJSPaths = `import { fileURLToPath as __gooseFile } from 'node:url';\nimport { dirname as __gooseDir } from 'node:path';\nconst __filename = __gooseFile(import.meta.url); const __dirname = __gooseDir(__filename);\n`;
      return { format: 'module', source: commonJSPaths + source, shortCircuit: true };
    }
    return nextLoad(url, context);
  },
  resolve(specifier, context, nextResolve) {
    if (context.parentURL?.startsWith(vendor)) {
      if (specifier === '../sqlite/sync-database') {
        return { url: new URL('./readonly-sqlite.mjs', import.meta.url).href, shortCircuit: true };
      }
      if (specifier === 'electron') {
        return { url: new URL('./electron.mjs', import.meta.url).href, shortCircuit: true };
      }
      if (specifier === '../kimi/kimi-runtime-home') {
        return { url: new URL('./kimi-home.mjs', import.meta.url).href, shortCircuit: true };
      }
      if (specifier.startsWith('.')) {
        return nextResolve(specifier + '.ts', context);
      }
    }
    return nextResolve(specifier, context);
  }
});
