import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { network } from "hardhat";
import { keccak256, encodePacked, parseEther } from "viem";

// One isolated chain state shared across this file. Each test restores a
// snapshot via loadFixture, so time warps in one test don't leak into the next.
const { viem, networkHelpers } = await network.create();

// Recompute the commitment exactly as the contract does:
// keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)).
function commitmentFor(
  answer: string,
  salt: `0x${string}`,
  submitter: `0x${string}`,
  bountyId: bigint,
): `0x${string}` {
  return keccak256(
    encodePacked(
      ["string", "bytes32", "address", "uint256"],
      [answer, salt, submitter, bountyId],
    ),
  );
}

const SALT_A = `0x${"a1".repeat(32)}` as `0x${string}`;
const SALT_B = `0x${"b2".repeat(32)}` as `0x${string}`;
const REWARD = parseEther("1");

// Deploy the contract and open one bounty whose deadlines are anchored to the
// current block time. Returns everything the tests need.
async function deployWithBounty() {
  const aiJudge = await viem.deployContract("AIJudge");
  const [owner, alice, bob] = await viem.getWalletClients();

  const now = await networkHelpers.time.latest();
  const submissionDeadline = BigInt(now + 1000);
  const revealDeadline = BigInt(now + 2000);

  await aiJudge.write.createBounty(
    ["Best haiku", "Judge on imagery", submissionDeadline, revealDeadline],
    { value: REWARD, account: owner.account },
  );

  const bountyId = 1n; // first bounty in a fresh deployment
  return { aiJudge, owner, alice, bob, bountyId, submissionDeadline, revealDeadline };
}

describe("AIJudge commit-reveal", () => {
  describe("createBounty", () => {
    it("rejects a reveal deadline that is not after the submission deadline", async () => {
      const { aiJudge, owner, submissionDeadline } =
        await networkHelpers.loadFixture(deployWithBounty);

      await viem.assertions.revertWith(
        aiJudge.write.createBounty(
          ["Bad", "rubric", submissionDeadline, submissionDeadline],
          { value: REWARD, account: owner.account },
        ),
        "reveal must follow submission",
      );
    });
  });

  describe("submitCommitment", () => {
    it("stores a commitment but keeps the answer hidden", async () => {
      const { aiJudge, alice, bountyId } =
        await networkHelpers.loadFixture(deployWithBounty);

      const commitment = commitmentFor(
        "the moon is bright",
        SALT_A,
        alice.account.address,
        bountyId,
      );
      await aiJudge.write.submitCommitment([bountyId, commitment], {
        account: alice.account,
      });

      const sub = await aiJudge.read.getSubmission([bountyId, 0n]);
      // [submitter, commitment, revealed, answer]
      assert.equal(sub[1], commitment);
      assert.equal(sub[2], false); // not revealed
      assert.equal(sub[3], ""); // answer is empty on-chain during submission
    });

    it("rejects a second commitment from the same participant", async () => {
      const { aiJudge, alice, bountyId } =
        await networkHelpers.loadFixture(deployWithBounty);

      const commitment = commitmentFor("a", SALT_A, alice.account.address, bountyId);
      await aiJudge.write.submitCommitment([bountyId, commitment], {
        account: alice.account,
      });

      await viem.assertions.revertWith(
        aiJudge.write.submitCommitment([bountyId, commitment], {
          account: alice.account,
        }),
        "already committed",
      );
    });

    it("rejects commitments after the submission deadline", async () => {
      const { aiJudge, alice, bountyId, submissionDeadline } =
        await networkHelpers.loadFixture(deployWithBounty);

      await networkHelpers.time.increaseTo(submissionDeadline);

      const commitment = commitmentFor("late", SALT_A, alice.account.address, bountyId);
      await viem.assertions.revertWith(
        aiJudge.write.submitCommitment([bountyId, commitment], {
          account: alice.account,
        }),
        "submissions closed",
      );
    });
  });

  describe("revealAnswer", () => {
    it("accepts a valid reveal in the reveal window", async () => {
      const { aiJudge, alice, bountyId, submissionDeadline } =
        await networkHelpers.loadFixture(deployWithBounty);

      const answer = "the moon is bright";
      const commitment = commitmentFor(answer, SALT_A, alice.account.address, bountyId);
      await aiJudge.write.submitCommitment([bountyId, commitment], {
        account: alice.account,
      });

      await networkHelpers.time.increaseTo(submissionDeadline);

      await aiJudge.write.revealAnswer([bountyId, answer, SALT_A], {
        account: alice.account,
      });

      const sub = await aiJudge.read.getSubmission([bountyId, 0n]);
      assert.equal(sub[2], true); // revealed
      assert.equal(sub[3], answer); // plaintext now visible

      const bounty = await aiJudge.read.getBounty([bountyId]);
      assert.equal(bounty.revealedCount, 1n);
    });

    it("rejects a reveal with the wrong salt", async () => {
      const { aiJudge, alice, bountyId, submissionDeadline } =
        await networkHelpers.loadFixture(deployWithBounty);

      const answer = "the moon is bright";
      const commitment = commitmentFor(answer, SALT_A, alice.account.address, bountyId);
      await aiJudge.write.submitCommitment([bountyId, commitment], {
        account: alice.account,
      });

      await networkHelpers.time.increaseTo(submissionDeadline);

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, answer, SALT_B], {
          account: alice.account,
        }),
        "commitment mismatch",
      );
    });

    it("rejects a reveal with a tampered answer", async () => {
      const { aiJudge, alice, bountyId, submissionDeadline } =
        await networkHelpers.loadFixture(deployWithBounty);

      const commitment = commitmentFor(
        "original answer",
        SALT_A,
        alice.account.address,
        bountyId,
      );
      await aiJudge.write.submitCommitment([bountyId, commitment], {
        account: alice.account,
      });

      await networkHelpers.time.increaseTo(submissionDeadline);

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, "swapped answer", SALT_A], {
          account: alice.account,
        }),
        "commitment mismatch",
      );
    });

    it("rejects a reveal before the submission deadline", async () => {
      const { aiJudge, alice, bountyId } =
        await networkHelpers.loadFixture(deployWithBounty);

      const answer = "too early";
      const commitment = commitmentFor(answer, SALT_A, alice.account.address, bountyId);
      await aiJudge.write.submitCommitment([bountyId, commitment], {
        account: alice.account,
      });

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, answer, SALT_A], {
          account: alice.account,
        }),
        "reveal not open",
      );
    });

    it("rejects a reveal after the reveal deadline", async () => {
      const { aiJudge, alice, bountyId, revealDeadline } =
        await networkHelpers.loadFixture(deployWithBounty);

      const answer = "too late";
      const commitment = commitmentFor(answer, SALT_A, alice.account.address, bountyId);
      await aiJudge.write.submitCommitment([bountyId, commitment], {
        account: alice.account,
      });

      await networkHelpers.time.increaseTo(revealDeadline);

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, answer, SALT_A], {
          account: alice.account,
        }),
        "reveal closed",
      );
    });

    it("rejects a reveal from someone who never committed", async () => {
      const { aiJudge, bob, bountyId, submissionDeadline } =
        await networkHelpers.loadFixture(deployWithBounty);

      await networkHelpers.time.increaseTo(submissionDeadline);

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, "anything", SALT_A], {
          account: bob.account,
        }),
        "no commitment",
      );
    });

    it("rejects a double reveal", async () => {
      const { aiJudge, alice, bountyId, submissionDeadline } =
        await networkHelpers.loadFixture(deployWithBounty);

      const answer = "only once";
      const commitment = commitmentFor(answer, SALT_A, alice.account.address, bountyId);
      await aiJudge.write.submitCommitment([bountyId, commitment], {
        account: alice.account,
      });

      await networkHelpers.time.increaseTo(submissionDeadline);
      await aiJudge.write.revealAnswer([bountyId, answer, SALT_A], {
        account: alice.account,
      });

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, answer, SALT_A], {
          account: alice.account,
        }),
        "already revealed",
      );
    });
  });

  describe("judging and finalization access control", () => {
    it("blocks judgeAll before the reveal deadline", async () => {
      const { aiJudge, owner, alice, bountyId, submissionDeadline } =
        await networkHelpers.loadFixture(deployWithBounty);

      const answer = "revealed answer";
      const commitment = commitmentFor(answer, SALT_A, alice.account.address, bountyId);
      await aiJudge.write.submitCommitment([bountyId, commitment], {
        account: alice.account,
      });
      await networkHelpers.time.increaseTo(submissionDeadline);
      await aiJudge.write.revealAnswer([bountyId, answer, SALT_A], {
        account: alice.account,
      });

      // Reverts on the timing guard before ever reaching the LLM precompile.
      await viem.assertions.revertWith(
        aiJudge.write.judgeAll([bountyId, "0x"], { account: owner.account }),
        "reveal not over",
      );
    });

    it("blocks judgeAll from a non-owner", async () => {
      const { aiJudge, bob, bountyId, revealDeadline } =
        await networkHelpers.loadFixture(deployWithBounty);

      await networkHelpers.time.increaseTo(revealDeadline);

      await viem.assertions.revertWith(
        aiJudge.write.judgeAll([bountyId, "0x"], { account: bob.account }),
        "not bounty owner",
      );
    });

    it("blocks finalizeWinner before judging", async () => {
      const { aiJudge, owner, bountyId } =
        await networkHelpers.loadFixture(deployWithBounty);

      await viem.assertions.revertWith(
        aiJudge.write.finalizeWinner([bountyId, 0n], { account: owner.account }),
        "not judged yet",
      );
    });
  });
});
