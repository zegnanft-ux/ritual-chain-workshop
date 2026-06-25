// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;

    function depositFor(address user, uint256 lockDuration) external payable;

    function withdraw(uint256 amount) external;

    function balanceOf(address) external view returns (uint256);

    function lockUntil(address) external view returns (uint256);
}

/// @title AIJudge — commit-reveal AI bounty judge
/// @notice Participants submit a hidden commitment during the submission phase
///         and only reveal their plaintext answer (plus salt) after the
///         submission deadline. This stops later participants from copying
///         earlier answers. Only valid, revealed answers are eligible for AI
///         judging and payout.
contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;
    uint256 public constant NO_WINNER = type(uint256).max;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    // One participant's entry. At commit time only `commitment` is known; the
    // plaintext `answer` stays empty on-chain until the participant reveals.
    struct Submission {
        address submitter;
        bytes32 commitment;
        string answer;
        bool revealed;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline; // commits allowed strictly before this
        uint256 revealDeadline; // reveals allowed in [submission, reveal)
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        uint256 revealedCount;
        Submission[] submissions;
        // 1-based index into `submissions` for each participant; 0 = none.
        mapping(address => uint256) commitmentSlot;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    // Read-only snapshot of a bounty. Returned as one memory struct so the
    // getter doesn't blow the EVM stack (a 12-value flat tuple would).
    struct BountyView {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        uint256 submissionCount;
        uint256 revealedCount;
        uint256 winnerIndex;
        bytes aiReview;
    }

    mapping(uint256 => Bounty) public bounties;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    /// @notice Create a bounty with a reward, a submission deadline and a
    ///         (later) reveal deadline. The escrowed reward is the ETH sent.
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(
            submissionDeadline > block.timestamp,
            "submission deadline in past"
        );
        require(
            revealDeadline > submissionDeadline,
            "reveal must follow submission"
        );

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];

        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = NO_WINNER;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    /// @notice Submit a hidden commitment. The plaintext answer stays off-chain.
    /// @dev commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp < bounty.submissionDeadline,
            "submissions closed"
        );
        require(commitment != bytes32(0), "empty commitment");
        require(bounty.commitmentSlot[msg.sender] == 0, "already committed");
        require(
            bounty.submissions.length < MAX_SUBMISSIONS,
            "too many submissions"
        );

        bounty.submissions.push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                answer: "",
                revealed: false
            })
        );

        uint256 index = bounty.submissions.length - 1;
        // store as 1-based so that 0 reliably means "no commitment"
        bounty.commitmentSlot[msg.sender] = index + 1;

        emit CommitmentSubmitted(bountyId, index, msg.sender, commitment);
    }

    /// @notice Reveal the plaintext answer + salt after the submission phase.
    ///         Accepted only if it hashes to the stored commitment.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.submissionDeadline,
            "reveal not open"
        );
        require(block.timestamp < bounty.revealDeadline, "reveal closed");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 slot = bounty.commitmentSlot[msg.sender];
        require(slot != 0, "no commitment");

        Submission storage submission = bounty.submissions[slot - 1];
        require(!submission.revealed, "already revealed");

        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(expected == submission.commitment, "commitment mismatch");

        submission.answer = answer;
        submission.revealed = true;
        bounty.revealedCount += 1;

        emit AnswerRevealed(bountyId, slot - 1, msg.sender);
    }

    /// @notice Batch-judge all revealed answers in a single LLM request.
    /// @dev Only callable after the reveal deadline. `llmInput` is built
    ///      off-chain from the revealed answers (see getRevealedSubmissions);
    ///      unrevealed submissions must not be included.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.revealDeadline, "reveal not over");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.revealedCount > 0, "no revealed answers");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /// @notice Owner finalizes a winner after judging and pays the reward.
    ///         The AI ranking is advisory; the human owner makes the final call.
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid index");

        Submission storage winnerSub = bounty.submissions[winnerIndex];
        require(winnerSub.revealed, "winner not revealed");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = winnerSub.submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0; // zero out before transfer (reentrancy hygiene)

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    /// @notice Recompute a commitment off-chain or in tests. Pure helper.
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }

    function getBounty(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (BountyView memory) {
        Bounty storage bounty = bounties[bountyId];

        return
            BountyView({
                owner: bounty.owner,
                title: bounty.title,
                rubric: bounty.rubric,
                reward: bounty.reward,
                submissionDeadline: bounty.submissionDeadline,
                revealDeadline: bounty.revealDeadline,
                judged: bounty.judged,
                finalized: bounty.finalized,
                submissionCount: bounty.submissions.length,
                revealedCount: bounty.revealedCount,
                winnerIndex: bounty.winnerIndex,
                aiReview: bounty.aiReview
            });
    }

    /// @notice Inspect a single submission. `answer` stays empty until revealed —
    ///         that is the whole point of commit-reveal.
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 commitment,
            bool revealed,
            string memory answer
        )
    {
        Bounty storage bounty = bounties[bountyId];

        require(index < bounty.submissions.length, "invalid index");

        Submission storage submission = bounty.submissions[index];

        return (
            submission.submitter,
            submission.commitment,
            submission.revealed,
            submission.answer
        );
    }

    /// @notice Return only the revealed submissions, for building the batch
    ///         `llmInput` off-chain. Returned indexes line up with on-chain
    ///         submission indexes so a winner maps back to a slot.
    function getRevealedSubmissions(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            uint256[] memory indexes,
            address[] memory submitters,
            string[] memory answers
        )
    {
        Bounty storage bounty = bounties[bountyId];
        uint256 n = bounty.revealedCount;

        indexes = new uint256[](n);
        submitters = new address[](n);
        answers = new string[](n);

        uint256 j;
        for (uint256 i = 0; i < bounty.submissions.length; i++) {
            Submission storage s = bounty.submissions[i];
            if (s.revealed) {
                indexes[j] = i;
                submitters[j] = s.submitter;
                answers[j] = s.answer;
                j++;
            }
        }
    }
}
