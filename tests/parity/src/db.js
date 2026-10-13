// Turf-js's database module as it is: the tests read and write documents directly.
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { TURF_JS } from '../zig.mjs';

const real = await import(pathToFileURL(path.join(TURF_JS, 'src/db.js')).href);
export const { connect, getDb, col, oid, client, ObjectId } = real;
