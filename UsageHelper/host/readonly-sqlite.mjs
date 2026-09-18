import { statSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import OriginalDatabase from '../vendor/orca/src/main/sqlite/sync-database.ts';

// SQLite readOnly alone may create a WAL shared-memory sidecar. Immutable avoids
// sidecar creation; refuse uncheckpointed WAL rather than silently omit its usage.
export default class ReadOnlyDatabase extends OriginalDatabase {
  constructor(path, options) {
    if (options?.readonly !== true || options?.fileMustExist !== true || typeof path !== 'string') {
      throw new Error('Usage database must be an existing read-only file');
    }
    if (!statSync(path).isFile()) throw new Error('Usage database is not a file');
    try {
      if (statSync(path + '-wal').size > 0) throw new Error('Active WAL usage database requires a checkpoint before read-only scanning');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    const url = pathToFileURL(path);
    url.search = 'mode=ro&immutable=1';
    super(url, { readonly: true, fileMustExist: true });
  }
}
