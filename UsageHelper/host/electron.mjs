// Node is launched with --use-env-proxy. These methods implement only the default
// environment-proxy session; isolated Chromium cookie/proxy sessions are not emulated.
const defaultSession = {
  fetch: (...args) => globalThis.fetch(...args),
  async resolveProxy() {
    const proxy = process.env.HTTPS_PROXY || process.env.HTTP_PROXY;
    return proxy ? `PROXY ${new URL(proxy).host}` : 'DIRECT';
  },
  async setProxy() {
    throw new Error('Changing proxy configuration requires an unsupported Chromium session');
  }
};
export const net = { fetch: (...args) => globalThis.fetch(...args) };
export const session = {
  defaultSession,
  fromPartition() {
    throw new Error('Isolated cookie sessions are not connected to this native host');
  }
};
export const app = {
  getPath() {
    throw new Error('Orca managed-account storage is not owned by this app');
  }
};
