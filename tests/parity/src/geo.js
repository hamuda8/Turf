import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { cli, TURF_JS } from '../zig.mjs';

const real = await import(pathToFileURL(path.join(TURF_JS, 'src/geo.js')).href);
export const { GOVERNORATES, GOVERNORATE_CODES, VEHICLES, VEHICLE_TYPES } = real;
export const distanceKm = (a, b) => cli('distanceKm', a, b);
