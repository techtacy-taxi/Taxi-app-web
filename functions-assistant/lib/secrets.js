// lib/secrets.js — ανάγνωση μυστικών tenant από το Secret Manager (ίδια ονοματολογία με το functions/).
const { SecretManagerServiceClient } = require("@google-cloud/secret-manager");

const client = new SecretManagerServiceClient();
const projectId = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || "my-taxi-app-bbc7c";
const cache = new Map();

function tenantSecretId(tenantId, field) {
  return `tenant-${tenantId}-${field}`;
}

async function readSecret(secretId) {
  const hit = cache.get(secretId);
  if (hit && Date.now() - hit.at < 10 * 60 * 1000) return hit.value;
  try {
    const [v] = await client.accessSecretVersion({
      name: `projects/${projectId}/secrets/${secretId}/versions/latest`,
    });
    const value = v.payload.data.toString("utf8");
    cache.set(secretId, { value, at: Date.now() });
    return value;
  } catch (e) {
    console.error("readSecret:", secretId, e && e.message ? e.message : e);
    return null;
  }
}

module.exports = { tenantSecretId, readSecret };
