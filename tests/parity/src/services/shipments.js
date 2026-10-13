import { cli } from '../../zig.mjs';

export const localToday = () => cli('localToday');
export const normalizeTrackingNumber = raw => cli('normalizeTrackingNumber', raw);
export const splitTrackingNumbers = text => cli('splitTrackingNumbers', text);
