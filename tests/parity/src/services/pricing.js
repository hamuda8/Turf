import { cli } from '../../zig.mjs';

export const quotePrice = (carrier, req) => cli('quotePrice', carrier, req);
export const chargeableKg = (p, weightKg, dims) => cli('chargeableKg', p, weightKg, dims);
export const zoneOf = (pickup, dropoff) => cli('zoneOf', pickup, dropoff);
export const promiseHours = (carrier, zone, service) => cli('promiseHours', carrier, zone, service);
export const expressReason = (carrier, req, now) => cli('expressReason', carrier, req, now);
export const openAt = (hours, now) => cli('openAt', hours, now);
