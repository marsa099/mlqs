// Exercise the actual Backend.qml recovery functions without a live OAuth account.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(new URL('../ui/Backend.qml', `file://${__filename}`), 'utf8');
function functionSource(name) {
    const start = source.indexOf(`    function ${name}(`);
    assert.notEqual(start, -1);
    let end = source.indexOf('{', start), depth = 1;
    while (depth) {
        end++;
        if (source[end] === '{') depth++;
        if (source[end] === '}') depth--;
    }
    return source.slice(start, end + 1);
}
function setup(unified = false) {
    const s = { inboxAuthErrors: {}, inboxAuthAccount: '', inboxAuthError: '',
        inboxAuthNeeded: 'work', inboxReauth: { running: false }, reauth: { running: false },
        accountFilter: unified ? '' : 'work', currentAccount: 'work', unified,
        loadingConvs: true, pendingCursor: 'old', _pagingAccounts: { work: true },
        _convsByAccount: { personal: [{ id: 'keep' }] }, sent: [], refreshed: 0,
        rebuilt: 0, fetched: [], notices: [],
        send(v) { s.sent.push(v); }, refresh() { s.refreshed++; },
        _rebuildMerged() { s.rebuilt++; }, _fetchUnifiedFor(a) { s.fetched.push(a); },
        accountLabel(a) { return a; }, toast(v) { s.notices.push(v); } };
    vm.createContext(s);
    for (const n of ['requireInboxAuth', 'startInboxReauth', 'dismissInboxReauth', '_inboxReauthFinished'])
        vm.runInContext(functionSource(n), s);
    return s;
}
let s = setup();
s.requireInboxAuth('work');
assert.equal(s.loadingConvs, false);
assert.equal(s.pendingCursor, '');
assert.equal(s.inboxAuthErrors.work, true);
assert.equal(s.inboxReauth.running, false, 'no automatic browser');
s.startInboxReauth();
assert.equal(s.inboxAuthAccount, 'work');
assert.equal(s.inboxReauth.running, true);
s._inboxReauthFinished(0);
assert.equal(s.inboxAuthErrors.work, undefined);
assert.equal(s.sent[0].type, 'folders');
assert.equal(s.refreshed, 1);
s = setup(true);
s.requireInboxAuth('work');
assert.equal(s._convsByAccount.personal[0].id, 'keep');
assert.equal(s._convsByAccount.work.length, 0);
assert.equal(s.rebuilt, 1);
s.startInboxReauth();
s._inboxReauthFinished(1);
assert.match(s.inboxAuthError, /not completed/);
assert.equal(s.inboxAuthErrors.work, true);
assert.equal(s.sent.length, 0);
s.inboxReauth.running = false;
s.startInboxReauth();
s._inboxReauthFinished(0);
assert.equal(s.fetched[0], 'work');
s = setup();
s.startInboxReauth();
s.dismissInboxReauth();
s._inboxReauthFinished(0);
assert.equal(s.sent.length, 0, 'cancel cannot retry');
s = setup();
s.reauth.running = true;
s.startInboxReauth();
assert.equal(s.inboxReauth.running, false, 'only one auth flow');
s = setup();
s.requireInboxAuth('personal');
assert.equal(s.loadingConvs, true, 'unrelated account must not stop current loading');
assert.match(source, /\["folders", "conversations", "search", "threads"\]\.indexOf\(e.operation\)/);
console.log('Inbox auth recovery tests passed');
