import { hook, Binary } from '../../zig.mjs';

export const adminView = orgId => hook('verification.adminView', orgId);
export async function getDocument(orgId, documentId) {
  const doc = await hook('verification.getDocument', orgId, documentId);
  return { ...doc, data: new Binary(doc.data) };
}
export const review = (orgId, admin, decision) => hook('verification.review', orgId, admin, decision);
