// Data from Turf-js (the client dictionaries are checked against it); texts from the Zig binary.
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { cli, TURF_JS } from '../zig.mjs';

const real = await import(pathToFileURL(path.join(TURF_JS, 'src/messages.js')).href);
export const { STATUSES, FINAL_STATUSES, VEHICLE_NAMES, FAILURE_REASONS, PROBLEM_TEXTS } = real;
export const eventText = (event, lang = 'en') => cli('eventText', event, lang);
export const statusText = (status, lang = 'en') => cli('statusText', status, lang);
