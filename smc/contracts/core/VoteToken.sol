// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "./interfaces/IVoteToken.sol";
import "./art/FistArt.sol";

/// @dev Minimal readers for the governance contracts VoteToken renders from.
interface IRoleRegistryReader {
    function rolesOf(uint256 jurisdictionId, bytes32 voterId) external view returns (uint256[] memory);
}
interface IRoleCatalogReader {
    function jurisdictionName(uint256 jurisdictionId) external view returns (string memory);
}

/**
 * @title VoteToken (V3)
 * @notice Soulbound jurisdiction badge that pairs with zk-based vote secrets.
 *         Tokens are never transferable, emit custody logs, and enforce a
 *         single active token per (voterId, jurisdictionId) pair.
 */
contract VoteToken is ERC721, AccessControl, IVoteToken {
    using Counters for Counters.Counter;
    using Strings for uint256;

    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    error SoulboundTransferBlocked();
    error ActiveTokenExists(bytes32 voterId, uint256 jurisdictionId);
    error TokenNotFound(uint256 tokenId);
    error TokenAlreadyDisabled(uint256 tokenId);

    struct TokenData {
        bytes32 voterId;
        uint256 jurisdictionId;
        bytes32 policyDigest;
        bytes32 cryptoVote;
        bytes32 signKey;
        bytes32 userBiometric;
        uint256 biometricTypeMask;
        bytes32 stealthCommitment;
        uint64 issuedAt;
        uint64 freezeEndsAt;
        uint64 disableTimestamp;
        uint32 revocationNonce;
        DisableReason disableReason;
        bool disabled;
        address disableSource;
    }

    Counters.Counter private _idTracker;
    mapping(uint256 => TokenData) private _tokenData;
    mapping(bytes32 => mapping(uint256 => uint256)) private _activeTokenByVoterJurisdiction;
    /// Live count of active (non-disabled) tokens per jurisdiction — the eligible-electorate
    /// denominator for turnout-based quorum (audit S1/S2 / GOVERNANCE G1). Maintained at the same
    /// active-slot transitions as `_activeTokenByVoterJurisdiction` (one active token per voter).
    mapping(uint256 => uint256) private _activeCountByJurisdiction;

    event TokenIssued(
        uint256 indexed tokenId,
        bytes32 indexed voterId,
        uint256 indexed jurisdictionId,
        address owner,
        address operator,
        bytes32 policyDigest,
        bytes32 stealthCommitment
    );

    event TokenCustodyHandover(
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        address newOwner,
        address operator,
        bytes32 stealthCommitment
    );

    event TokenFrozen(
        uint256 indexed tokenId,
        address indexed operator,
        uint64 freezeEndsAt,
        uint32 revocationNonce,
        string reason
    );

    event TokenUnfrozen(uint256 indexed tokenId, address indexed operator);

    event TokenDisabled(
        uint256 indexed tokenId,
        address indexed operator,
        DisableReason reason,
        uint64 disabledAt,
        uint32 revocationNonce
    );

    event TokenSecretsUpdated(
        uint256 indexed tokenId,
        address indexed operator,
        bytes32 signKey,
        bytes32 policyDigest,
        uint32 revocationNonce
    );

    constructor() ERC721("Real Democracy", "VOTE") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CUSTODIAN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Render sources (set post-deploy; roles/name live in separate contracts)
    // ---------------------------------------------------------------------

    // JurisdictionRoleRegistry — read for the holder's role pill (try/catch in tokenURI).
    address public roleRegistry;
    // RoleCatalog — read for the jurisdiction display name (try/catch in tokenURI).
    address public roleCatalog;

    event RoleRegistryUpdated(address indexed registry);
    event RoleCatalogUpdated(address indexed catalog);

    function setRoleRegistry(address registry) external onlyRole(ADMIN_ROLE) {
        roleRegistry = registry;
        emit RoleRegistryUpdated(registry);
    }

    function setRoleCatalog(address catalogAddress) external onlyRole(ADMIN_ROLE) {
        roleCatalog = catalogAddress;
        emit RoleCatalogUpdated(catalogAddress);
    }

    // ---------------------------------------------------------------------
    // IVoteToken implementation
    // ---------------------------------------------------------------------

    function issueToken(
        address to,
        bytes32 voterId,
        uint256 jurisdictionId,
        Secrets calldata secrets,
        bytes32 policyDigest,
        bytes32 stealthCommitment
    ) external override onlyRole(CUSTODIAN_ROLE) returns (uint256 tokenId) {
        tokenId = _issueTokenInternal(
            to,
            voterId,
            jurisdictionId,
            secrets,
            policyDigest,
            stealthCommitment,
            _msgSender()
        );
    }

    function handoverCustody(
        uint256 tokenId,
        address newOwner,
        Secrets calldata secrets,
        bytes32 stealthCommitment
    ) external override onlyRole(CUSTODIAN_ROLE) returns (uint256 newTokenId) {
        TokenData storage data = _requireToken(tokenId);
        if (data.disabled) revert TokenAlreadyDisabled(tokenId);

        _disableToken(tokenId, DisableReason.Custodian, _msgSender());

        newTokenId = _issueTokenInternal(
            newOwner,
            data.voterId,
            data.jurisdictionId,
            secrets,
            data.policyDigest,
            stealthCommitment,
            _msgSender()
        );

        emit TokenCustodyHandover(tokenId, newTokenId, newOwner, _msgSender(), stealthCommitment);
    }

    function selfDisable(uint256 tokenId) external override {
        if (ownerOf(tokenId) != _msgSender()) revert("Only holder");
        _disableToken(tokenId, DisableReason.Self, _msgSender());
    }

    function adminDisable(uint256 tokenId) external override onlyRole(ADMIN_ROLE) {
        _disableToken(tokenId, DisableReason.Administrator, _msgSender());
    }

    function custodianDisable(uint256 tokenId) external override onlyRole(CUSTODIAN_ROLE) {
        _disableToken(tokenId, DisableReason.Custodian, _msgSender());
    }

    function freezeToken(uint256 tokenId, uint64 freezeForSeconds, string calldata reason)
        external
        override
        onlyRole(ADMIN_ROLE)
    {
        TokenData storage data = _requireToken(tokenId);
        if (data.disabled) revert TokenAlreadyDisabled(tokenId);

        uint64 freezeEnds = freezeForSeconds == 0
            ? type(uint64).max
            : uint64(block.timestamp) + freezeForSeconds;

        data.freezeEndsAt = freezeEnds;
        data.revocationNonce += 1;

        emit TokenFrozen(tokenId, _msgSender(), freezeEnds, data.revocationNonce, reason);
    }

    function unfreezeToken(uint256 tokenId) external override onlyRole(ADMIN_ROLE) {
        TokenData storage data = _requireToken(tokenId);
        if (data.freezeEndsAt == 0) return;

        data.freezeEndsAt = 0;
        data.revocationNonce += 1;

        emit TokenUnfrozen(tokenId, _msgSender());
    }

    function isActive(uint256 tokenId) public view override returns (bool) {
        TokenData storage data = _requireToken(tokenId);
        if (data.disabled) {
            return false;
        }
        if (data.freezeEndsAt != 0) {
            if (data.freezeEndsAt == type(uint64).max) {
                return false;
            }
            if (block.timestamp <= data.freezeEndsAt) {
                return false;
            }
        }
        return true;
    }

    function jurisdictionIdOf(uint256 tokenId) external view override returns (uint256) {
        return _requireToken(tokenId).jurisdictionId;
    }

    function voterIdOf(uint256 tokenId) external view override returns (bytes32) {
        return _requireToken(tokenId).voterId;
    }

    function revocationNonceOf(uint256 tokenId) external view override returns (uint32) {
        return _requireToken(tokenId).revocationNonce;
    }

    function activeTokenOf(bytes32 voterId, uint256 jurisdictionId)
        external
        view
        override
        returns (uint256 tokenId)
    {
        tokenId = _activeTokenByVoterJurisdiction[voterId][jurisdictionId];
    }

    /// Live count of active (non-disabled) tokens in a jurisdiction — the eligible-electorate size,
    /// the denominator for turnout-based quorum (audit S1/S2 / GOVERNANCE G1). (Frozen tokens still
    /// count as electorate members; only `disable` removes one — see `_disableToken`.)
    function activeTokenCount(uint256 jurisdictionId) external view returns (uint256) {
        return _activeCountByJurisdiction[jurisdictionId];
    }

    function tokenInfo(uint256 tokenId) external view override returns (TokenInfo memory info) {
        TokenData storage data = _requireToken(tokenId);
        bool frozen = data.freezeEndsAt != 0 &&
            (data.freezeEndsAt == type(uint64).max || block.timestamp <= data.freezeEndsAt);

        info = TokenInfo({
            voterId: data.voterId,
            jurisdictionId: data.jurisdictionId,
            policyDigest: data.policyDigest,
            cryptoVote: data.cryptoVote,
            signKey: data.signKey,
            userBiometric: data.userBiometric,
            biometricTypeMask: data.biometricTypeMask,
            stealthCommitment: data.stealthCommitment,
            disabled: data.disabled,
            frozen: frozen,
            issuedAt: data.issuedAt,
            freezeEndsAt: data.freezeEndsAt,
            disableTimestamp: data.disableTimestamp,
            revocationNonce: data.revocationNonce,
            disableReason: data.disableReason,
            disableSource: data.disableSource
        });
    }

    // ---------------------------------------------------------------------
    // Administrative helpers
    // ---------------------------------------------------------------------

    function updateSecrets(
        uint256 tokenId,
        Secrets calldata secrets,
        bytes32 policyDigest
    ) external override onlyRole(CUSTODIAN_ROLE) {
        TokenData storage data = _requireToken(tokenId);
        if (data.disabled) revert TokenAlreadyDisabled(tokenId);

        data.cryptoVote = secrets.cryptoVote;
        data.signKey = secrets.signKey;
        data.userBiometric = secrets.userBiometric;
        data.biometricTypeMask = secrets.biometricTypeMask;
        data.policyDigest = policyDigest;
        data.revocationNonce += 1;

        emit TokenSecretsUpdated(tokenId, _msgSender(), secrets.signKey, policyDigest, data.revocationNonce);
    }

    /**
     * @dev Temporary bridge for legacy minter until full V3 integration lands.
     *      Mints a token with zeroed secrets and hashed jurisdiction identifiers.
     */
    function mint(address to, bool forEnsemble, bytes32 forShow)
        external
        onlyRole(CUSTODIAN_ROLE)
        returns (uint256 tokenId)
    {
        uint256 jurisdictionId = forEnsemble
            ? uint256(1)
            : uint256(keccak256(abi.encodePacked("JURISDICTION", forShow)));
        uint256 nextId = _idTracker.current() + 1;
        bytes32 voterId = keccak256(
            abi.encodePacked("LEGACY_MINT", to, jurisdictionId, nextId, block.timestamp)
        );

        Secrets memory secrets = Secrets({
            cryptoVote: bytes32(0),
            signKey: bytes32(0),
            userBiometric: bytes32(0),
            biometricTypeMask: 0
        });

        tokenId = _issueTokenInternal(
            to,
            voterId,
            jurisdictionId,
            secrets,
            bytes32(0),
            bytes32(0),
            _msgSender()
        );
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _issueTokenInternal(
        address to,
        bytes32 voterId,
        uint256 jurisdictionId,
        Secrets memory secrets,
        bytes32 policyDigest,
        bytes32 stealthCommitment,
        address operator
    ) private returns (uint256 tokenId) {
        require(to != address(0), "Invalid owner");
        require(voterId != bytes32(0), "Invalid voterId");
        require(jurisdictionId != 0, "Invalid jurisdiction");

        if (_activeTokenByVoterJurisdiction[voterId][jurisdictionId] != 0) {
            revert ActiveTokenExists(voterId, jurisdictionId);
        }

        _idTracker.increment();
        tokenId = _idTracker.current();
        _safeMint(to, tokenId);

        TokenData storage data = _tokenData[tokenId];
        data.voterId = voterId;
        data.jurisdictionId = jurisdictionId;
        data.policyDigest = policyDigest;
        data.cryptoVote = secrets.cryptoVote;
        data.signKey = secrets.signKey;
        data.userBiometric = secrets.userBiometric;
        data.biometricTypeMask = secrets.biometricTypeMask;
        data.stealthCommitment = stealthCommitment;
        data.issuedAt = uint64(block.timestamp);
        data.freezeEndsAt = 0;
        data.disableTimestamp = 0;
        data.revocationNonce = 0;
        data.disableReason = DisableReason.None;
        data.disabled = false;
        data.disableSource = address(0);

        _activeTokenByVoterJurisdiction[voterId][jurisdictionId] = tokenId;
        _activeCountByJurisdiction[jurisdictionId] += 1; // G1 turnout denominator

        emit TokenIssued(tokenId, voterId, jurisdictionId, to, operator, policyDigest, stealthCommitment);
    }

    function _disableToken(uint256 tokenId, DisableReason reason, address actor) private {
        TokenData storage data = _requireToken(tokenId);
        if (data.disabled) {
            revert TokenAlreadyDisabled(tokenId);
        }

        data.disabled = true;
        data.disableTimestamp = uint64(block.timestamp);
        data.disableSource = actor;
        data.disableReason = reason;
        data.revocationNonce += 1;

        if (_activeTokenByVoterJurisdiction[data.voterId][data.jurisdictionId] == tokenId) {
            _activeTokenByVoterJurisdiction[data.voterId][data.jurisdictionId] = 0;
            _activeCountByJurisdiction[data.jurisdictionId] -= 1; // G1 turnout denominator
        }

        emit TokenDisabled(tokenId, actor, reason, data.disableTimestamp, data.revocationNonce);
    }

    function _requireToken(uint256 tokenId) private view returns (TokenData storage data) {
        data = _tokenData[tokenId];
        if (_ownerOf(tokenId) == address(0)) {
            revert TokenNotFound(tokenId);
        }
    }

    // ---------------------------------------------------------------------
    // On-chain metadata (fully self-contained data: URI — no server, no IPFS)
    // ---------------------------------------------------------------------

    // Working set for rendering, passed by reference to keep the stack shallow.
    struct Render {
        string id;        // token id
        string jName;     // jurisdiction display name (or "Jurisdiction <id>")
        string accent;    // status accent (ring/fist/glow)
        string roleLabel; string rPl; string rPd; string rText;   // role pill
        string stLabel;   string sPl; string sPd; string sText;   // state pill
    }

    /**
     * @notice ERC-721 metadata rendered entirely on-chain as a base64 data URI —
     *         a "Real Democracy" coin badge with the holder's jurisdiction name,
     *         live role (read from JurisdictionRoleRegistry), and lifecycle status.
     *         Self-contained: wallets/explorers render it even if every backend is
     *         offline. Role + name come from separate contracts via try/catch, so
     *         the badge still renders if they're unset/unreachable.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        TokenData storage data = _requireToken(tokenId);

        Render memory r;
        r.id = tokenId.toString();
        r.jName = _jurisdictionLabel(data.jurisdictionId);
        string memory statusMixed = _fillStatus(r, data);
        _fillRole(r, data.jurisdictionId, data.voterId);

        string memory json = string.concat(
            '{"name":"Real Democracy VoteToken #', r.id,
            '","description":"Soulbound civic voting badge on the Real Democracy network (built by the JUX Foundation). Non-transferable proof of voting membership in a jurisdiction.",',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(_renderSVG(r))),
            '","attributes":[',
                '{"trait_type":"Jurisdiction","value":"', r.jName, '"},',
                '{"trait_type":"Role","value":"', r.roleLabel, '"},',
                '{"trait_type":"Status","value":"', statusMixed, '"},',
                '{"display_type":"date","trait_type":"Issued","value":', uint256(data.issuedAt).toString(), '},',
                '{"trait_type":"Revocation Nonce","value":', uint256(data.revocationNonce).toString(), '}',
            ']}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @dev Jurisdiction name from RoleCatalog, falling back to "Jurisdiction <id>".
    function _jurisdictionLabel(uint256 jurisdictionId) private view returns (string memory) {
        if (roleCatalog != address(0)) {
            try IRoleCatalogReader(roleCatalog).jurisdictionName(jurisdictionId) returns (string memory n) {
                if (bytes(n).length > 0) return n;
            } catch {}
        }
        return string.concat("Jurisdiction ", jurisdictionId.toString());
    }

    /// @dev Fills status accent + state-pill colors on `r`; returns mixed-case status.
    function _fillStatus(Render memory r, TokenData storage data) private view returns (string memory) {
        if (data.disabled) {
            r.accent = "#f87171"; r.stLabel = "DISABLED"; r.sPl = "#cbd5e1"; r.sPd = "#94a3b8"; r.sText = "#0f172a";
            return "Disabled";
        }
        if (
            data.freezeEndsAt != 0 &&
            (data.freezeEndsAt == type(uint64).max || block.timestamp <= data.freezeEndsAt)
        ) {
            r.accent = "#ffb347"; r.stLabel = "FROZEN"; r.sPl = "#ffe066"; r.sPd = "#ffb347"; r.sText = "#2b1700";
            return "Frozen";
        }
        r.accent = "#00ffb2"; r.stLabel = "ACTIVE"; r.sPl = "#36ffad"; r.sPd = "#0fd976"; r.sText = "#00231a";
        return "Active";
    }

    /// @dev Fills the role pill on `r`. Reads JurisdictionRoleRegistry (try/catch);
    ///      maps the top-priority catalog role (admin>proposer>token_guardian) to a
    ///      pill, defaulting every holder to the green "VOTER" base role.
    function _fillRole(Render memory r, uint256 jurisdictionId, bytes32 voterId) private view {
        uint256 top = 0;
        if (roleRegistry != address(0)) {
            try IRoleRegistryReader(roleRegistry).rolesOf(jurisdictionId, voterId) returns (uint256[] memory ids) {
                for (uint256 i = 0; i < ids.length; i++) {
                    uint256 rid = ids[i];
                    if (rid == 1) { top = 1; break; }            // admin
                    else if (rid == 2 && top != 1) top = 2;       // proposer
                    else if (rid == 20 && top == 0) top = 20;     // token_guardian
                }
            } catch {}
        }
        if (top == 1) { r.roleLabel = "ADMIN"; r.rPl = "#36ffad"; r.rPd = "#0fd976"; r.rText = "#002317"; }
        else if (top == 2) { r.roleLabel = "PROPOSER"; r.rPl = "#ffe066"; r.rPd = "#ffb347"; r.rText = "#2b1700"; }
        else if (top == 20) { r.roleLabel = "TOKEN GUARDIAN"; r.rPl = "#00ffb2"; r.rPd = "#00bcd4"; r.rText = "#00231a"; }
        else { r.roleLabel = "VOTER"; r.rPl = "#00ffb2"; r.rPd = "#00d68f"; r.rText = "#00231a"; }
    }

    /// @dev Coin-card SVG mirroring the frontend JurisdictionTokenCard: navy gradient
    ///      body, glowing accent coin with the Real Democracy fist, role + state pills.
    function _renderSVG(Render memory r) private pure returns (string memory) {
        string memory head = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' width='500' height='500' viewBox='0 0 500 500'><defs>",
            "<radialGradient id='bg' cx='18%' cy='14%' r='90%'><stop offset='0%' stop-color='#111830'/><stop offset='55%' stop-color='#060812'/><stop offset='100%' stop-color='#04060f'/></radialGradient>",
            "<linearGradient id='ring' x1='0' y1='0' x2='1' y2='1'><stop offset='0%' stop-color='#ffffff' stop-opacity='0.6'/><stop offset='45%' stop-color='", r.accent, "'/><stop offset='100%' stop-color='", r.accent, "' stop-opacity='0.5'/></linearGradient>",
            "<radialGradient id='glow' cx='50%' cy='50%' r='50%'><stop offset='0%' stop-color='", r.accent, "' stop-opacity='0.35'/><stop offset='100%' stop-color='", r.accent, "' stop-opacity='0'/></radialGradient></defs>"
        );
        string memory coin = string.concat(
            "<rect width='500' height='500' rx='28' fill='url(#bg)'/>",
            "<rect x='10' y='10' width='480' height='480' rx='24' fill='none' stroke='url(#ring)' stroke-width='2' opacity='0.6'/>",
            "<circle cx='250' cy='188' r='148' fill='url(#glow)'/>",
            "<circle cx='250' cy='188' r='116' fill='#0a0e1c' stroke='url(#ring)' stroke-width='6'/>",
            "<circle cx='250' cy='188' r='102' fill='none' stroke='#ffffff' stroke-opacity='0.12' stroke-width='1.5'/>",
            "<g transform='translate(202.8,115) scale(0.0286)' fill='", r.accent, "'><path fill-rule='evenodd' d='", FistArt.PATH, "'/></g>"
        );
        string memory text = string.concat(
            "<text x='250' y='350' text-anchor='middle' fill='#ffffff' font-family='Helvetica,Arial,sans-serif' font-size='32' font-weight='bold'>Real Democracy</text>",
            "<text x='250' y='378' text-anchor='middle' fill='#ffffff' fill-opacity='0.55' font-family='Helvetica,Arial,sans-serif' font-size='15' letter-spacing='1'>", r.jName, " &#183; #", r.id, "</text>"
        );
        return string.concat(head, coin, text, _pills(r), "</svg>");
    }

    function _pills(Render memory r) private pure returns (string memory) {
        uint256 rw = 26 + bytes(r.roleLabel).length * 13;
        uint256 sw = 26 + bytes(r.stLabel).length * 13;
        uint256 total = rw + sw + 14;
        uint256 rcx = 250 - total / 2 + rw / 2;
        uint256 scx = 250 + total / 2 - sw / 2;
        return string.concat(
            _pill(rcx, r.roleLabel, r.rPl, r.rPd, r.rText, "rp"),
            _pill(scx, r.stLabel, r.sPl, r.sPd, r.sText, "sp")
        );
    }

    function _pill(
        uint256 cx,
        string memory label,
        string memory pl,
        string memory pd,
        string memory textColor,
        string memory gid
    ) private pure returns (string memory) {
        uint256 w = 26 + bytes(label).length * 13;
        return string.concat(
            "<linearGradient id='", gid, "' x1='0' y1='0' x2='1' y2='0'><stop offset='0%' stop-color='", pl, "'/><stop offset='100%' stop-color='", pd, "'/></linearGradient>",
            "<rect x='", (cx - w / 2).toString(), "' y='430' width='", w.toString(), "' height='32' rx='16' fill='url(#", gid, ")'/>",
            "<text x='", cx.toString(), "' y='451' text-anchor='middle' fill='", textColor, "' font-family='Helvetica,Arial,sans-serif' font-size='14' font-weight='bold' letter-spacing='1'>", label, "</text>"
        );
    }

    // ---------------------------------------------------------------------
    // Soulbound enforcement + ERC165
    // ---------------------------------------------------------------------

    function approve(address, uint256) public pure override {
        revert SoulboundTransferBlocked();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert SoulboundTransferBlocked();
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal
        override
    {
        if (from != address(0) && to != address(0)) {
            revert SoulboundTransferBlocked();
        }
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return interfaceId == type(IVoteToken).interfaceId || super.supportsInterface(interfaceId);
    }
}
