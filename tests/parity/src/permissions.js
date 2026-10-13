import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { cli, TURF_JS } from '../zig.mjs';

const real = await import(pathToFileURL(path.join(TURF_JS, 'src/permissions.js')).href);
export const { PERMISSIONS, DEFAULT_ROLES } = real;
export const isSubset = (candidate, of) => cli('isSubset', candidate, [...of]);
