# Active-credential tally prototype (#918)

This harness proves the central transition using real Groth16 proofs and exports
`ActiveCredentialTallyVerifier.sol` for an on-chain development rehearsal:

1. Three credentials have persistent standing votes (`for`, `against`, `for`).
2. Freezing the third credential changes the active-credential root, electorate,
   and effective tally while the standing-ballot root remains unchanged.
3. Unfreezing restores the original active root and tally without a new vote.

Run from `vote/smc`:

```sh
./scripts/build_active_tally_prototype.sh
```

All per-credential commitments, status bits, and choices are private circuit
inputs. Only roots and aggregate totals are public.

After building, verify the same transitions through the EVM pairing verifier and
the state adapter:

```sh
npx hardhat test test/ActiveCredentialTallyRollup.integration.test.js
```

`ActiveCredentialTallyRollup` pins a ballot's standing-choice root on its first
accepted proof. Later activity epochs may change the active-credential root and
effective totals, but cannot silently replace standing choices. The test submits
baseline, freeze, and unfreeze proofs, then confirms a tampered public tally is
rejected. No credential or individual choice is disclosed on chain.

## Cryptographic limitations

This is intentionally not deployable production cryptography. It uses an
ordered eight-slot Poseidon vector instead of a scalable authenticated state
tree and a development-only Groth16 ceremony. Although the prototype now has a
real on-chain verifier and state adapter, it does not yet prove that an
active-root transition was authorized by `VoteToken`; therefore it must not be
used as a production governance source.
Differencing two public aggregate states can reveal the changed contribution
when the anonymity set is small or external timing identifies the frozen user.
Production work still needs recursive/batched state transitions, contract-bound
status updates, delegation precedence, data availability, and a real ceremony
or transparent proof system.
