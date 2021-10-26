%lang starknet
%builtins pedersen range_check ecdsa

from starkware.cairo.common.hash import hash2
from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.math import assert_not_zero, assert_le, assert_nn
from starkware.starknet.common.storage import Storage
from starkware.starknet.common.syscalls import call_contract

####################
# CONSTANTS
####################

const CHANGE_SIGNER_SELECTOR = 1540130945889430637313403138889853410180247761946478946165786566748520529557
const CHANGE_GUARDIAN_SELECTOR = 1374386526556551464817815908276843861478960435557596145330240747921847320237
const CHANGE_L1_ADDRESS_SELECTOR = 279169963369459328778917024654659648799474594494056791695540097993562699432
const TRIGGER_ESCAPE_SELECTOR = 654787765132774538659281525944449989569480594447680779882263455595827967108
const CANCEL_ESCAPE_SELECTOR = 992575500541331354489361836180456905167517944319528538469723604173440834912
const ESCAPE_GUARDIAN_SELECTOR = 1662889347576632967292303062205906116436469425870979472602094601074614456040
const ESCAPE_SIGNER_SELECTOR = 578307412324655990419134484880427622068887477430675222732446709420063579565
const IS_VALID_SIGNATURE_SELECTOR = 1138073982574099226972715907883430523600275391887289231447128254784345409857

const ESCAPE_SECURITY_PERIOD = 500 # set to e.g. 7 days in prod

####################
# STRUCTS
####################

struct Escape:
    member active_at: felt
    member caller: felt
end

struct Signature:
    member sig_r: felt
    member sig_s: felt
end

####################
# STORAGE VARIABLES
####################

@storage_var
func _self_address() -> (res: felt):
end

@storage_var
func _current_nonce() -> (res: felt):
end

@storage_var
func _initialized() -> (res: felt):
end

@storage_var
func _signer() -> (res: felt):
end

@storage_var
func _guardian() -> (res: felt):
end

@storage_var
func _escape() -> (res: Escape):
end

@storage_var
func _L1_address() -> (res: felt):
end

####################
# EXTERNAL FUNCTIONS
####################

@external
func initialize{
        storage_ptr: Storage*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } (
        signer: felt,
        guardian: felt,
        L1_address: felt,
        self_address: felt
    ):
    # check that the contract is not initialized
    let (initialized) = _initialized.read()
    assert initialized = 0
    # check that the signer and self_address are not zero
    assert_not_zero(signer)
    assert_not_zero(self_address)
    # initialize the contract
    _initialized.write(1)
    _signer.write(signer)
    _guardian.write(guardian)
    _L1_address.write(L1_address)
    _self_address.write(self_address)
    return ()
end

@external
func execute{
        storage_ptr: Storage*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        syscall_ptr: felt*,
        range_check_ptr
    } (
        to: felt,
        selector: felt,
        calldata_len: felt,
        calldata: felt*,
        nonce: felt,
        sig_len: felt,
        sig: felt*
    ) -> (response : felt):
    alloc_locals

    # cast sig to an array of Signature struct until natively supported by Cairo
    let (local signatures_len, local signatures) = cast_to_signature(sig_len, sig)

    # validate and bump nonce
    validate_and_bump_nonce(nonce)

    # validate signatures
    let (local message_hash) = get_message_hash(to, selector, calldata_len, calldata, nonce)
    validate_signer_signature(message_hash, signatures, signatures_len, 0)
    validate_guardian_signature(message_hash, signatures, signatures_len, 1)

    # execute call
    let response = call_contract(
        contract_address=to,
        function_selector=selector,
        calldata_size=calldata_len,
        calldata=calldata
    )

    return (response=response.retdata_size)
end

@external
func change_signer{
        storage_ptr: Storage*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    } (
        new_signer: felt,
        nonce: felt,
        sig_len: felt,
        sig: felt*
    ):
    alloc_locals

    # cast sig to an array of Signature struct until natively supported by Cairo
    let (local signatures_len, local signatures) = cast_to_signature(sig_len, sig)

    # validate and bump nonce
    validate_and_bump_nonce(nonce)

    # validate signatures
    let (to) = _self_address.read()
    let calldata: felt* = alloc()
    assert calldata[0] = new_signer
    let (local message_hash) = get_message_hash(to, CHANGE_SIGNER_SELECTOR, 1, calldata, nonce)
    validate_signer_signature(message_hash, signatures, signatures_len, 0)
    validate_guardian_signature(message_hash, signatures, signatures_len, 1)

    # change signer
    assert_not_zero(new_signer)
    _signer.write(new_signer)
    return()
end

@external
func change_guardian{
        storage_ptr: Storage*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    } (
        new_guardian: felt,
        nonce: felt,
        sig_len: felt,
        sig: felt*
    ):
    alloc_locals

    # cast sig to an array of Signature struct until natively supported by Cairo
    let (local signatures_len, local signatures) = cast_to_signature(sig_len, sig)

    # validate and bump nonce
    validate_and_bump_nonce(nonce)

    # validate signatures
    let (to) = _self_address.read()
    let calldata: felt* = alloc()
    assert calldata[0] = new_guardian
    let (local message_hash) = get_message_hash(to, CHANGE_GUARDIAN_SELECTOR, 1, calldata, nonce)
    validate_signer_signature(message_hash, signatures, signatures_len, 0)
    validate_guardian_signature(message_hash, signatures, signatures_len, 1)

    # change guardian
    assert_not_zero(new_guardian)
    _guardian.write(new_guardian)
    return()
end

@external
func change_L1_address{
        storage_ptr: Storage*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    } (
        new_L1_address: felt,
        nonce: felt,
        sig_len: felt,
        sig: felt*
    ):
    alloc_locals

    # cast sig to an array of Signature struct until natively supported by Cairo
    let (local signatures_len, local signatures) = cast_to_signature(sig_len, sig)

    # validate and bump nonce
    validate_and_bump_nonce(nonce)

    # validate signatures
    let (to) = _self_address.read()
    let calldata: felt* = alloc()
    assert calldata[0] = new_L1_address
    let (local message_hash) = get_message_hash(to, CHANGE_L1_ADDRESS_SELECTOR, 1, calldata, nonce)
    validate_signer_signature(message_hash, signatures, signatures_len, 0)
    validate_guardian_signature(message_hash, signatures, signatures_len, 1)

    # change guardian
    _L1_address.write(new_L1_address)
    return()
end

@external
func trigger_escape{
        storage_ptr: Storage*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    } (
        escapor: felt,
        nonce: felt,
        sig_len: felt,
        sig: felt*
    ):
    alloc_locals

    # cast sig to an array of Signature struct until natively supported by Cairo
    let (local signatures_len, local signatures) = cast_to_signature(sig_len, sig)

    # validate and bump nonce
    validate_and_bump_nonce(nonce)

    # no escape when the guardian is not set
    let (local guardian) = _guardian.read()
    assert_not_zero(guardian)

    # check if there is already an escape
    let (local current_escape) = _escape.read()
    let (local signer) = _signer.read()
    if current_escape.active_at != 0:
        assert current_escape.caller = guardian
        assert escapor = signer
    end

    # validate signature
    let (to) = _self_address.read()
    let calldata: felt* = alloc()
    assert calldata[0] = escapor
    let (local message_hash) = get_message_hash(to, TRIGGER_ESCAPE_SELECTOR, 1, calldata, nonce)
    if escapor == signer:
        validate_signer_signature(message_hash, signatures, signatures_len, 0)
    else:
        assert escapor = guardian
        validate_guardian_signature(message_hash, signatures, signatures_len, 0) 
    end

    # rebinding ptrs
    local ecdsa_ptr: SignatureBuiltin* = ecdsa_ptr  

    # store new escape
    let (block_timestamp) = _block_timestamp.read()
    local new_escape: Escape = Escape(block_timestamp + ESCAPE_SECURITY_PERIOD, escapor)
    _escape.write(new_escape)
    return()
end

@external
func cancel_escape{
        storage_ptr: Storage*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    } (
        nonce: felt,
        sig_len: felt,
        sig: felt*
    ):
    alloc_locals

    # cast sig to an array of Signature struct until natively supported by Cairo
    let (local signatures_len, local signatures) = cast_to_signature(sig_len, sig)

    # validate and bump nonce
    validate_and_bump_nonce(nonce)

    # validate there is an active escape
    let (local current_escape) = _escape.read()
    assert_not_zero(current_escape.active_at)

    # validate signatures
    let (to) = _self_address.read()
    let calldata: felt* = alloc()
    let (local message_hash) = get_message_hash(to, CANCEL_ESCAPE_SELECTOR, 0, calldata, nonce)
    validate_signer_signature(message_hash, signatures, signatures_len, 0)
    validate_guardian_signature(message_hash, signatures, signatures_len, 1)

    # clear escape
    local new_escape: Escape = Escape(0, 0)
    _escape.write(new_escape)
    return()
end

@external
func escape_guardian{
        storage_ptr: Storage*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    } (
        new_guardian: felt,
        nonce: felt,
        sig_len: felt,
        sig: felt*
    ):
    alloc_locals

    # cast sig to an array of Signature struct until natively supported by Cairo
    let (local signatures_len, local signatures) = cast_to_signature(sig_len, sig)

    # validate and bump nonce
    validate_and_bump_nonce(nonce)

    # validate there is an active escape
    let (local block_timestamp) = _block_timestamp.read()
    let (local current_escape) = _escape.read()
    assert_le(current_escape.active_at, block_timestamp)

    # validate signer signatures
    let (to) = _self_address.read()
    let calldata: felt* = alloc()
    assert calldata[0] = new_guardian
    let (local message_hash) = get_message_hash(to, ESCAPE_GUARDIAN_SELECTOR, 1, calldata, nonce)
    validate_signer_signature(message_hash, signatures, signatures_len, 0)

    # clear escape
    local new_escape: Escape = Escape(0, 0)
    _escape.write(new_escape)

    # change guardian
    assert_not_zero(new_guardian)
    _guardian.write(new_guardian)

    return()
end

@external
func escape_signer{
        storage_ptr: Storage*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    } (
        new_signer: felt,
        nonce: felt,
        sig_len: felt,
        sig: felt*
    ):
    alloc_locals

    # cast sig to an array of Signature struct until natively supported by Cairo
    let (local signatures_len, local signatures) = cast_to_signature(sig_len, sig)

    # validate and bump nonce
    validate_and_bump_nonce(nonce)

    # validate there is an active escape
    let (local block_timestamp) = _block_timestamp.read()
    let (local current_escape) = _escape.read()
    assert_le(current_escape.active_at, block_timestamp)

    # validate signer signatures
    let (to) = _self_address.read()
    let calldata: felt* = alloc()
    assert calldata[0] = new_signer
    let (local message_hash) = get_message_hash(to, ESCAPE_SIGNER_SELECTOR, 1, calldata, nonce)
    validate_guardian_signature(message_hash, signatures, signatures_len, 0)

    # clear escape
    local new_escape: Escape = Escape(0, 0)
    _escape.write(new_escape)

    # change signer
    assert_not_zero(new_signer)
    _signer.write(new_signer)

    return()
end

####################
# VIEW FUNCTIONS
####################

@view
func is_valid_signature{
        storage_ptr: Storage*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        syscall_ptr: felt*,
        range_check_ptr
    } (
        hash: felt,
        sig_len: felt,
        sig: felt*
    ) -> (magic_value: felt):
    alloc_locals

    # cast sig to an array of Signature struct until natively supported by Cairo
    let (local signatures_len, local signatures) = cast_to_signature(sig_len, sig)

    validate_signer_signature(hash, signatures, signatures_len, 0)
    validate_guardian_signature(hash, signatures, signatures_len, 1)
    return (magic_value = IS_VALID_SIGNATURE_SELECTOR)
end

@view
func get_current_nonce{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr}() -> (nonce: felt):
    let (res) = _current_nonce.read()
    return (nonce=res)
end

@view
func get_initialized{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr}() -> (initialized: felt):
    let (res) = _initialized.read()
    return (initialized=res)
end

@view
func get_signer{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr}() -> (signer: felt):
    let (res) = _signer.read()
    return (signer=res)
end

@view
func get_guardian{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr}() -> (guardian: felt):
    let (res) = _guardian.read()
    return (guardian=res)
end

@view
func get_escape{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr}() -> (active_at: felt, caller: felt):
    let (res) = _escape.read()
    return (active_at=res.active_at, caller=res.caller)
end

@view
func get_L1_address{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr}() -> (L1_address: felt):
    let (res) = _L1_address.read()
    return (L1_address=res)
end

####################
# INTERNAL FUNCTIONS
####################

func validate_and_bump_nonce{
        storage_ptr : Storage*, 
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    } (
        message_nonce: felt
    ) -> ():
    let (current_nonce) = _current_nonce.read()
    assert current_nonce = message_nonce
    _current_nonce.write(current_nonce + 1)
    return()
end

func validate_signer_signature{
        storage_ptr : Storage*, 
        pedersen_ptr : HashBuiltin*,
        ecdsa_ptr : SignatureBuiltin*,
        range_check_ptr
    } (
        message: felt, 
        signatures: Signature*,
        signatures_len: felt,
        position: felt
    ) -> ():
    assert_le(position, signatures_len - 1) 
    let (signer) = _signer.read()
    verify_ecdsa_signature(
        message=message,
        public_key=signer,
        signature_r=signatures[position].sig_r,
        signature_s=signatures[position].sig_s)
    return()
end

func validate_guardian_signature{
        storage_ptr : Storage*, 
        pedersen_ptr : HashBuiltin*,
        ecdsa_ptr : SignatureBuiltin*,
        range_check_ptr
    } (
        message: felt,
        signatures: Signature*,
        signatures_len: felt,
        position: felt
    ) -> ():
    let (guardian) = _guardian.read()
    if guardian == 0:
        return()
    else:
        assert_le(position, signatures_len - 1)
        verify_ecdsa_signature(
            message=message,
            public_key=guardian,
            signature_r=signatures[position].sig_r,
            signature_s=signatures[position].sig_s)
        return()
    end
end

func get_message_hash{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    ecdsa_ptr : SignatureBuiltin*,
    range_check_ptr}(to: felt, selector: felt, calldata_len: felt, calldata: felt*, nonce: felt) -> (res: felt):
    alloc_locals
    let (account) = _self_address.read()
    let (res) = hash2{hash_ptr=pedersen_ptr}(account, to)
    let (res) = hash2{hash_ptr=pedersen_ptr}(res, selector)
    # we need to make `res` local
    # to prevent the reference from being revoked
    local storage_ptr : Storage* = storage_ptr
    local range_check_ptr = range_check_ptr
    local res = res
    let (res_calldata) = hash_calldata(calldata, calldata_len)
    let (res) = hash2{hash_ptr=pedersen_ptr}(res, res_calldata)
    let (res) = hash2{hash_ptr=pedersen_ptr}(res, nonce)
    return (res=res)
end

func hash_calldata{pedersen_ptr: HashBuiltin*}(
        calldata: felt*,
        calldata_size: felt
    ) -> (res: felt):
    if calldata_size == 0:
        return (res=0)
    end

    if calldata_size == 1:
        return (res=[calldata])
    end

    let _calldata = [calldata]
    let (res) = hash_calldata(calldata + 1, calldata_size - 1)
    let (res) = hash2{hash_ptr=pedersen_ptr}(res, _calldata)
    return (res=res)
end

####################
# TMP HACK
####################

@storage_var
func _block_timestamp() -> (res: felt):
end

@view
func get_block_timestamp{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr}() -> (block_timestamp: felt):
    let (res) = _block_timestamp.read()
    return (block_timestamp=res)
end

@external
func set_block_timestamp{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr}(new_block_timestamp: felt):
    _block_timestamp.write(new_block_timestamp)
    return ()
end

func cast_to_signature{
        range_check_ptr
    } (
        array_len: felt,
        array: felt*
    ) -> (sig_len: felt, sig: Signature*):
    let sig_len = array_len / Signature.SIZE
    assert_nn(sig_len)
    let sig = cast (array, Signature*)
    return (sig_len=sig_len,sig=sig)
end