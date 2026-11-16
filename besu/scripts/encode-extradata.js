#!/usr/bin/env node
// Generate IBFT2 extraData for genesis file

const rlp = require('rlp');

// Validator address (without 0x prefix)
const validator = '04bf808983c76374bf0e743f2e492da646dff886';

// IBFT2 extraData structure:
// [32-byte vanity, [validator addresses], vote, round]
const vanity = Buffer.alloc(32); // 32 zero bytes
const validators = [Buffer.from(validator, 'hex')];
const vote = Buffer.alloc(0); // empty
const round = Buffer.alloc(0); // empty

const extraDataList = [vanity, validators, vote, round];
const extraData = '0x' + rlp.encode(extraDataList).toString('hex');

console.log('Validator address:', '0x' + validator);
console.log('extraData:', extraData);
