// E2E здесь не реализован: для полноценного теста нужен docker-compose
// окружения с реальным iptables/ipset (их вызывают LockdownService на старте,
// чтобы создать vless_lockdown ipset). Юнит-тесты в src/**/*.spec.ts покрывают
// чистую логику (buildConfig, normalize, dedupe).
describe('AppModule (e2e placeholder)', () => {
  it.skip('TODO: integration test via docker-compose with real iptables/ipset', () => {
    // см. AUDIT.md задача 2.10 / haproxy-node-wrz
  });
});
