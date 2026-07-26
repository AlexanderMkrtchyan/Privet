import {
  canGrantControl,
  canRelayCallSignal,
  canRequestControl,
  buildControlSignalOutbound,
} from '../src/ws/call_auth.js';

function assert(cond, msg) {
  if (!cond) {
    console.error('FAIL:', msg);
    process.exitCode = 1;
  } else {
    console.log('ok:', msg);
  }
}

const active = {
  id: 'c1',
  status: 'active',
  fromUserId: 'alice',
  toUserId: 'bob',
};

const ringing = { ...active, status: 'ringing' };

assert(canRelayCallSignal(active, 'alice', 'bob') === true, 'participant can relay');
assert(canRelayCallSignal(active, 'bob', 'alice') === true, 'peer can relay');
assert(canRelayCallSignal(active, 'alice', 'carol') === false, 'wrong target rejected');
assert(canRelayCallSignal(active, 'carol', 'bob') === false, 'stranger rejected');
assert(canRelayCallSignal(ringing, 'alice', 'bob') === false, 'ringing cannot relay media');
assert(canRelayCallSignal(null, 'alice', 'bob') === false, 'missing call rejected');
assert(canRequestControl(active, 'alice', 'bob') === true, 'request allowed for peer');
assert(canGrantControl(active, 'bob', 'alice') === true, 'grant allowed for peer');
assert(canGrantControl(active, 'eve', 'alice') === false, 'grant from stranger rejected');

const denyWithReason = buildControlSignalOutbound(
  { type: 'call.control_deny', reason: '  portal timed out  ' },
  { callId: 'c1', fromUserId: 'bob', toUserId: 'alice' },
);
assert(denyWithReason.reason === 'portal timed out', 'deny reason is trimmed and forwarded');

const denyNoReason = buildControlSignalOutbound(
  { type: 'call.control_deny' },
  { callId: 'c1', fromUserId: 'bob', toUserId: 'alice' },
);
assert(denyNoReason.reason === undefined, 'deny without reason omits field');

const grantOutbound = buildControlSignalOutbound(
  { type: 'call.control_grant', reason: 'ignored' },
  { callId: 'c1', fromUserId: 'bob', toUserId: 'alice' },
);
assert(grantOutbound.reason === undefined, 'grant does not forward reason');

const longReason = 'x'.repeat(600);
const denyLong = buildControlSignalOutbound(
  { type: 'call.control_deny', reason: longReason },
  { callId: 'c1', fromUserId: 'bob', toUserId: 'alice' },
);
assert(denyLong.reason.length === 500, 'deny reason is capped at 500 chars');

if (process.exitCode) {
  console.error('server call auth tests failed');
  process.exit(1);
}
console.log('all server call auth tests passed');
