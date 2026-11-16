pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/comparators.circom";

// #918 development prototype. This deliberately uses a fixed eight-leaf
// vector. It proves the state model; it is not the production accumulator.
template ActiveCredentialTally(n) {
    // Private standing state. credentialCommitment is a pseudorandom binding
    // to a VoteToken credential, not an address or token id.
    signal input credentialCommitment[n];
    signal input occupied[n];
    signal input active[n];
    signal input hasVote[n];
    signal input choice[n]; // 0 = against, 1 = for, 2 = abstain

    // Public commitments and effective result.
    signal input activeCredentialRoot;
    signal input standingBallotRoot;
    signal input electorate;
    signal input counted;
    signal input againstTotal;
    signal input forTotal;
    signal input abstainTotal;

    signal activeChain[n + 1];
    signal ballotChain[n + 1];
    signal electorateAcc[n + 1];
    signal countedAcc[n + 1];
    signal againstAcc[n + 1];
    signal forAcc[n + 1];
    signal abstainAcc[n + 1];
    activeChain[0] <== 0;
    ballotChain[0] <== 0;
    electorateAcc[0] <== 0;
    countedAcc[0] <== 0;
    againstAcc[0] <== 0;
    forAcc[0] <== 0;
    abstainAcc[0] <== 0;

    component activeHash[n];
    component ballotHash[n];
    component isAgainst[n];
    component isFor[n];
    component isAbstain[n];
    component choiceRange[n];
    signal effective[n];

    for (var i = 0; i < n; i++) {
        occupied[i] * (1 - occupied[i]) === 0;
        active[i] * (1 - active[i]) === 0;
        hasVote[i] * (1 - hasVote[i]) === 0;
        active[i] * (1 - occupied[i]) === 0;
        hasVote[i] * (1 - occupied[i]) === 0;
        // Empty slots are canonical and cannot hide credentials or choices.
        credentialCommitment[i] * (1 - occupied[i]) === 0;
        choice[i] * (1 - occupied[i]) === 0;

        choiceRange[i] = LessThan(2);
        choiceRange[i].in[0] <== choice[i];
        choiceRange[i].in[1] <== 3;
        choiceRange[i].out === 1;

        activeHash[i] = Poseidon(4);
        activeHash[i].inputs[0] <== activeChain[i];
        activeHash[i].inputs[1] <== credentialCommitment[i];
        activeHash[i].inputs[2] <== occupied[i];
        activeHash[i].inputs[3] <== active[i];
        activeChain[i + 1] <== activeHash[i].out;

        // Crucially, active status is absent: freezing does not erase or alter
        // the standing choice commitment.
        ballotHash[i] = Poseidon(4);
        ballotHash[i].inputs[0] <== ballotChain[i];
        ballotHash[i].inputs[1] <== credentialCommitment[i];
        ballotHash[i].inputs[2] <== hasVote[i];
        ballotHash[i].inputs[3] <== choice[i];
        ballotChain[i + 1] <== ballotHash[i].out;

        isAgainst[i] = IsEqual();
        isAgainst[i].in[0] <== choice[i];
        isAgainst[i].in[1] <== 0;
        isFor[i] = IsEqual();
        isFor[i].in[0] <== choice[i];
        isFor[i].in[1] <== 1;
        isAbstain[i] = IsEqual();
        isAbstain[i].in[0] <== choice[i];
        isAbstain[i].in[1] <== 2;

        effective[i] <== active[i] * hasVote[i];
        electorateAcc[i + 1] <== electorateAcc[i] + active[i];
        countedAcc[i + 1] <== countedAcc[i] + effective[i];
        againstAcc[i + 1] <== againstAcc[i] + effective[i] * isAgainst[i].out;
        forAcc[i + 1] <== forAcc[i] + effective[i] * isFor[i].out;
        abstainAcc[i + 1] <== abstainAcc[i] + effective[i] * isAbstain[i].out;
    }

    // Reject duplicate occupied credentials (one-current-choice invariant).
    component distinct[n * (n - 1) / 2];
    signal pairOccupied[n * (n - 1) / 2];
    var k = 0;
    for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
            distinct[k] = IsEqual();
            distinct[k].in[0] <== credentialCommitment[i];
            distinct[k].in[1] <== credentialCommitment[j];
            pairOccupied[k] <== occupied[i] * occupied[j];
            distinct[k].out * pairOccupied[k] === 0;
            k++;
        }
    }

    activeChain[n] === activeCredentialRoot;
    ballotChain[n] === standingBallotRoot;
    electorateAcc[n] === electorate;
    countedAcc[n] === counted;
    againstAcc[n] === againstTotal;
    forAcc[n] === forTotal;
    abstainAcc[n] === abstainTotal;
}

component main { public [activeCredentialRoot, standingBallotRoot, electorate,
    counted, againstTotal, forTotal, abstainTotal] } = ActiveCredentialTally(8);
