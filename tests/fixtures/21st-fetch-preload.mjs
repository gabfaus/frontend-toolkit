const port = Number(process.env.FTK_TEST_21ST_PORT);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('FTK_TEST_21ST_PORT is invalid.');
}

const realFetch = globalThis.fetch;
globalThis.fetch = (input, init) => {
  const rawUrl = typeof input === 'string'
    ? input
    : input instanceof URL
      ? input.href
      : input.url;
  const url = new URL(rawUrl);
  if (url.origin === 'https://21st.dev' && url.pathname === '/api/mcp' &&
      url.search === '' && url.hash === '') {
    return realFetch('http://127.0.0.1:' + port + '/api/mcp', init);
  }
  return realFetch(input, init);
};
