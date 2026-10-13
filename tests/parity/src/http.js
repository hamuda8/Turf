// src/http.js for the parity tests: the validators run in the Zig binary.
import { cli, HttpError } from '../zig.mjs';

export { HttpError };
const call = name => (value, field, opts = {}) => cli(`V.${name}`, value, field, opts);
export const V = { str: call('str'), num: call('num'), bool: call('bool'), phone: call('phone'), email: call('email'), slug: call('slug'), hexColor: call('hexColor') };
