import {
  decodeTrainerJson,
  looksLikeTrainerCheck,
  mergeTrainerReplies,
  repairTruncatedJson,
  splitTrainerChunks,
} from '../src/ai/trainer_json.js';
import { parseAiInput } from '../src/ai/chat.js';

function assert(cond, msg) {
  if (!cond) {
    console.error('FAIL:', msg);
    process.exitCode = 1;
  } else {
    console.log('ok:', msg);
  }
}

const original =
  'Have you updated Privet? If no, can you update and se how it is correcting me.\n\nlong text like this almost always coac can\'t read.';

const parsed = parseAiInput(`# english-check\n${original}`);
assert(parsed?.type === 'english_check', 'parseAiInput keeps multiline english-check body');
assert(parsed?.text === original, 'parseAiInput does not drop the second paragraph');

const truncated = `{"issues":[
 {"wrong":"If no","right":"If not","type":"word_choice","severity":"minor","why":"Use if not.","example":"If not, call me."},
 {"wrong":"coac","right":"coach","type":"spelling","severity":"major","why":"Spelling.","example":"The coach can read it."}
],"quip":"Almost — one letter shy.","cefr":"B1","natural":"If not, update and see how`;
assert(looksLikeTrainerCheck(truncated), 'truncated coach JSON is still readable');
const repaired = decodeTrainerJson(truncated);
assert(Array.isArray(repaired?.issues) && repaired.issues.length === 2, 'repair keeps both issues');
assert(repaired.issues[1].right === 'coach', 'last complete issue survives');

const fenced = '```json\n{"issues":[],"quip":"Clean.","cefr":"A2"\n';
assert(looksLikeTrainerCheck(fenced), 'unclosed fence + truncated object parses');

const bare = '[{"wrong":"se","right":"see","type":"spelling"}]';
assert(looksLikeTrainerCheck(bare), 'bare issues array is accepted');

const chunks = splitTrainerChunks(`${'a'.repeat(400)}\n\n${'b'.repeat(400)}`, 700);
assert(chunks.length === 2, 'long two-paragraph message splits');
assert(chunks[0].includes('aaa') && chunks[1].includes('bbb'), 'chunks keep paragraph text');

const merged = JSON.parse(
  mergeTrainerReplies([
    '{"issues":[{"wrong":"If no","right":"If not"}],"quip":"Nice try.","cefr":"B1"}',
    '{"issues":[{"wrong":"coac","right":"coach"}],"cefr":"A2"}',
  ]),
);
assert(merged.issues.length === 2, 'chunk replies merge issues');
assert(merged.quip === 'Nice try.', 'first quip wins');

const closed = repairTruncatedJson('{"issues":[');
assert(closed === '{"issues":[]}', 'empty open array closes');

if (process.exitCode) {
  console.error('trainer_json tests failed');
} else {
  console.log('trainer_json tests passed');
}
