import { hook } from '../../zig.mjs';
import { outbox } from '../mailer.js';

async function refresh() {
  const sent = await hook('outbox');
  outbox.length = 0;
  outbox.push(...sent);
}
export const startEmails = () => { hook('startEmails').catch(() => {}); };
export const processEmailQueue = async (opts = {}) => { await hook('processEmailQueue', opts); await refresh(); };
export const sendDailySummaries = async now => { await hook('sendDailySummaries', now); await refresh(); };
