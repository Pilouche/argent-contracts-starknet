import { assert, expect } from "chai";
import { readFileSync } from "fs";
import {
  CallData,
  CompiledSierra,
  CompiledSierraCasm,
  Contract,
  DeclareContractPayload,
  InvokeTransactionReceiptResponse,
  RawArgs,
  hash,
  json,
  shortString,
} from "starknet";

import { account, provider } from "./constants";

async function declareContract(contractName: string) {
  console.log(`\tDeclaring ${contractName}...`);
  const contract: CompiledSierra = json.parse(readFileSync(`./contracts/${contractName}.json`).toString("ascii"));
  try {
    const casm: CompiledSierraCasm = json.parse(readFileSync(`./contracts/${contractName}.casm`).toString("ascii"));
    return await actualDeclare({ contract, casm });
  } catch (e) {
    return await actualDeclare({ contract });
  }
}

async function actualDeclare(payload: DeclareContractPayload) {
  const hash = await account
    .declare(payload)
    .then(async (deployResponse) => {
      await account.waitForTransaction(deployResponse.transaction_hash);
      return deployResponse.class_hash;
    })
    .catch((e) => {
      return extractHashFromErrorOrCrash(e);
    });
  console.log(`\t\t✅ Declared at ${hash}`);
  return hash;
}

// Could make a cache to optimize speed
async function deployAndLoadContract(classHash: string, calldata: RawArgs = {}) {
  const constructorCalldata = CallData.compile(calldata);
  const { transaction_hash, contract_address } = await account.deployContract({ classHash, constructorCalldata });
  await provider.waitForTransaction(transaction_hash);
  return loadContract(contract_address);
}

async function loadContract(contract_address: string) {
  const { abi: testAbi } = await provider.getClassAt(contract_address);
  if (!testAbi) {
    throw new Error("Error while getting ABI");
  }
  return new Contract(testAbi, contract_address, provider);
}
async function deployAndLoadAccountContract(classHash: string, owner: number, guardian = 0) {
  return await deployAndLoadContract(classHash, { owner, guardian });
}

async function expectRevertWithErrorMessage(errorMessage: string, fn: () => void) {
  try {
    await fn();
    assert.fail("No error detected");
  } catch (e: any) {
    expect(e.toString()).to.contain(shortString.encodeShortString(errorMessage));
  }
}

async function expectEvent(transactionHash: string, eventName: string, data: string[] = []) {
  const txReceiptDeployTest: InvokeTransactionReceiptResponse = await provider.waitForTransaction(transactionHash);
  if (!txReceiptDeployTest.events) {
    assert.fail("No events triggered");
  }
  const selector = hash.getSelectorFromName(eventName);
  const event = txReceiptDeployTest.events.filter((e) => e.keys[0] == selector);
  if (event.length == 0) {
    assert.fail(`No event detected in this transaction: ${transactionHash}`);
  }
  if (event.length > 1) {
    assert.fail("Unsupported: Multiple events with same selector detected");
  }
  expect(event[0].data).to.eql(data);
}

function extractHashFromErrorOrCrash(e: string) {
  const hashRegex = /hash\s+(0x[a-fA-F\d]+)/;
  const matches = e.toString().match(hashRegex);
  if (matches !== null) {
    return matches[1];
  } else {
    throw e;
  }
}

export {
  provider,
  account,
  declareContract,
  loadContract,
  deployAndLoadContract,
  deployAndLoadAccountContract,
  expectRevertWithErrorMessage,
  expectEvent,
};
