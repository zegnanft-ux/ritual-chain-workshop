# AI Bounty Judge — Commit-Reveal version

This is my homework for the Ritual AI Bounty Judge workshop. The original app had a
problem: when you submitted an answer it was stored in plain text on-chain, so anyone could
read it. That means a late person could just copy an earlier answer, tweak it, and win.
Not fair. So I changed it so answers stay hidden until the submission phase is over.

- Track I did: the required one (commit-reveal). I also wrote up the advanced Ritual/TEE
  idea as a design note since the homework said that part can be a design doc.
- Contract: [`hardhat/contracts/AIJudge.sol`](hardhat/contracts/AIJudge.sol)
- Tests: [`hardhat/test/AIJudge.ts`](hardhat/test/AIJudge.ts) — 14 of them, all passing.

## What was wrong before

The old `submitAnswer` did basically this:

```solidity
bounty.submissions.push(Submission({ submitter: msg.sender, answer: answer }));
```

The whole answer goes straight onto the chain in plain text. Everything on-chain is public,
so anyone reading the contract sees every answer the moment it's submitted. In a bounty
where only one person wins, that lets people copy.

## How commit-reveal fixes it

The idea is you do it in two steps:

1. **Commit phase** — instead of your answer, you send a *hash* of it. A hash is one-way, so
   nobody can read your answer from it, but you also can't change your answer later (any
   change makes a totally different hash).
2. **Reveal phase** — after submissions close, you send the real answer + a secret value
   (salt). The contract re-hashes it and checks it matches what you committed earlier.

The hash I use:

```solidity
commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
```

Why each piece is in there:

| Piece | Reason |
| --- | --- |
| `answer` | the thing we're hiding |
| `salt` | a random secret so people can't just guess short answers and brute-force the hash |
| `msg.sender` | ties the commitment to you, so nobody can steal your hash and reveal it as theirs |
| `bountyId` | so the same commitment can't be reused on another bounty |

(Small detail I learned: `abi.encodePacked` can be unsafe if you pack two dynamic things
next to each other, but here only `answer` is dynamic and the rest are fixed size, so it's
fine.)

## The lifecycle

```
createBounty -> submitCommitment (xN) -> [submission deadline]
                                              |
                                              v
                       revealAnswer (xN) -> [reveal deadline]
                                              |
                                              v
                   judgeAll (Ritual AI, batch) -> finalizeWinner (owner pays)
```

| Step | Function | Who | When |
| --- | --- | --- | --- |
| Create | `createBounty(title, rubric, submissionDeadline, revealDeadline)` | owner | puts up the reward as msg.value |
| Commit | `submitCommitment(bountyId, commitment)` | anyone | before the submission deadline |
| Reveal | `revealAnswer(bountyId, answer, salt)` | the committer | between the two deadlines |
| Judge | `judgeAll(bountyId, llmInput)` | owner | after the reveal deadline |
| Finalize | `finalizeWinner(bountyId, winnerIndex)` | owner | after judging |

### Rules the contract actually enforces

- You can only commit before the submission deadline.
- You can only reveal between the submission and reveal deadlines.
- One commitment per person per bounty (I track this with a 1-based `commitmentSlot`
  mapping, where 0 means "never committed").
- A reveal only works if the hash matches.
- Answers that never got revealed can't win — you need at least one revealed answer to
  judge, and the winner you finalize has to be marked `revealed`.
- Owner can only judge after the reveal deadline, and only finalize after judging.
- One winner gets paid, and I zero out the reward before sending it (so nobody can
  re-enter and drain it).

### Who picks the winner — the AI or me?

Both, but split on purpose. `judgeAll` sends all the revealed answers to Ritual's LLM in
**one** batch call (the homework says don't loop one call per answer) and saves what the AI
says. But the AI only **suggests**. Then the owner (a human) calls `finalizeWinner` with the
index and that's what actually pays out. I didn't make the contract auto-pay from the AI's
text, because parsing LLM output on-chain to move real money is risky — if the output is
malformed or someone messes with the prompt, you'd pay the wrong person with no undo.

## Running it

Everything runs from the `hardhat/` folder:

```bash
pnpm install          # first time only
pnpm hardhat build    # compile the contract
pnpm hardhat test     # run the 14 tests
```

Heads up: I had to add `verifyDepsBeforeRun: false` and allow the `esbuild` build script in
`pnpm-workspace.yaml`, otherwise pnpm's dependency check kept failing before Hardhat even
ran (the `ERR_PNPM_IGNORED_BUILDS` error). If that ever happens to you, `npx hardhat <cmd>`
skips the pnpm wrapper and just works.

## Tests

`hardhat/test/AIJudge.ts` has 14 tests covering the reveal cases plus access control:

| What it checks | Cases |
| --- | --- |
| Valid reveal | right answer + salt in the window -> revealed, answer shows up, count goes up |
| Bad reveal | wrong salt, changed answer -> reverts with "commitment mismatch" |
| Timing | committing too late, revealing too early, revealing too late |
| One-per-person | second commitment, revealing twice, revealing without committing |
| Access control | non-owner judging, judging too early, finalizing before judging |

The test re-computes the commitment hash itself in TypeScript (with viem) instead of asking
the contract, so it's actually proving the contract's formula is the one I documented.

**About the judge step:** I couldn't fully test `judgeAll` locally because it calls Ritual's
LLM precompile (`0x0802`), which only exists on the real Ritual chain, not the local test
network. So the tests check the guards around it instead. If you run it on Ritual chain, the
manual test would be:

1. Create a bounty with short deadlines.
2. Two accounts commit; check `getSubmission` shows an empty answer.
3. After the submission deadline, both reveal; check the answers show up and the revealed
   count is 2.
4. After the reveal deadline, owner builds `llmInput` from `getRevealedSubmissions` and
   calls `judgeAll`; check it emits `AllAnswersJudged`.
5. Owner calls `finalizeWinner` with the AI's pick; check the reward goes to the winner.
6. Try finalizing an answer that was never revealed -> should revert.

## Commit-reveal vs the Ritual-native (TEE) way

| | Commit-reveal (what I built) | Ritual-native / TEE (the advanced idea) |
| --- | --- | --- |
| Hidden during submission | Yes (only hashes on-chain) | Yes (only encrypted data on-chain) |
| Hidden during **judging** | No — answers are public once revealed, before the AI judges | Yes — plaintext only exists inside the TEE |
| Where the plain answer lives | your computer, then fully on-chain after reveal | your computer -> encrypted -> only decrypted inside the Ritual TEE |
| What's on-chain | the hash, then the full answer | an encrypted blob or an off-chain reference + a hash |
| Trust you're relying on | hashing + honest deadlines | the TEE being secure + key handling |
| Works on any EVM chain | Yes | No, needs Ritual's TEE/privacy features |

So the honest limitation of commit-reveal: it only hides answers *during submission*. Once
the reveal phase happens, everything is public — including before the AI scores it. It stops
copying, but it's not full privacy.

The Ritual-native version would fix that:

1. Each person encrypts their answer for the Ritual TEE and submits only the ciphertext (or
   an off-chain reference plus a hash, to keep gas down).
2. Before judging, nobody — not other people, not even the owner — can read the answers.
3. `judgeAll` runs inside the TEE, which decrypts everything privately and sends all answers
   to the LLM as one batch, so plaintext never hits the public chain.
4. The TEE gives back a result like `{ winnerIndex, ranking, revealedAnswersRef,
   revealedAnswersHash, summary }`, and the contract stores the hash so the revealed bundle
   can be verified.
5. After judging, the answers (or a reference to them) get revealed all together, so nobody
   ever had an information advantage.

That actually uses Ritual for more than just calling an LLM: TEE execution, encrypted
inputs, batch judging, and still a human finalizing the payout.

## Reflection

Honestly, before this i didnt really think about what should be hidden in a n app like this, but now i get it more. I think the bounty rules should always be public like the reward, the rubric, and the deadlines. Because if people dont know what they're competing for or how they get judged, its not fair. The answers though should stay hidden until the timer ends, because if everyone can see them early, people will just copy the good ones and win. After judging is done i think its okay for the answers to become public so people cna check it wasnt rigged. For the judging part i think ai should just help read and give like a score or like oh this is wrong or its off. Human should still be the one to actually pick the winner and send the money. For ritual in this AIjudge bounty project, the main thing it adds is that it lets the ai actually do the judging on-chain instead of on some random server you'd have to trust. And with the TEE it could even judge the answers while they're still secret (encrypted) — which a normal blockchain can't do, since it can only store public stuff.

## Honesty note

I built this with help from Claude (the AI assistant) as a coding partner I'd ask it to
explain things, then we'd write and test the code together. I made sure I actually
understood each part instead of just pasting: how the commitment hash works and why
`msg.sender` and `bountyId` go inside it, why the answer stays empty on-chain until reveal,
why the winner has to be a revealed submission, and why the human owner finalizes instead of
the AI auto-paying. The `pnpm` / `esbuild` build error was real and took a few tries to
figure out. The reflection above I'm writing on my own.
