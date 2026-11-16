// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "./art/FistArt.sol";

interface IVoteTokenJurisdictionView {
    function isActive(uint256 tokenId) external view returns (bool);
    function jurisdictionIdOf(uint256 tokenId) external view returns (uint256);
}

/// @dev Minimal reader for the jurisdiction display name — the same contract
///      VoteToken.tokenURI renders from, so the PTS badge and the VoteToken badge agree.
interface IRoleCatalogReader {
    function jurisdictionName(uint256 jurisdictionId) external view returns (string memory);
}

/**
 * @title JurisdictionPts1155Bank
 * @notice Jurisdiction-scoped, non-transferable points bank.
 *         tokenId MUST equal jurisdictionId.
 */
contract JurisdictionPts1155Bank is ERC1155, AccessControl {
    using Strings for uint256;

    bytes32 public constant BANK_OPERATOR_ROLE = keccak256("BANK_OPERATOR_ROLE");
    bytes32 public constant JURISDICTION_FACTORY_ROLE = keccak256("JURISDICTION_FACTORY_ROLE");

    string private constant DEFAULT_ACCENT = "#00ffb2";

    IERC721 public immutable voteToken721;
    IVoteTokenJurisdictionView public immutable voteToken;

    // RoleCatalog — read for the jurisdiction display name (try/catch in uri()).
    address public roleCatalog;

    mapping(uint256 => address) public jurisdictionGovernors;
    mapping(uint256 => bool) public jurisdictionConfigured;
    mapping(uint256 => mapping(address => bool)) private _jurisdictionOperators;
    /// @notice Stable settlement contexts consumed by wallet-recipient mint/burn calls.
    /// @dev New wallet flows use this as the final chain-level idempotency guard.
    mapping(bytes32 => bool) public processedWalletContexts;
    // jurisdictionId => hex accent color (e.g. "#00ffb2") for the on-chain PTS badge SVG.
    // Governable per-jurisdiction (same authority as operators) so each jurisdiction can carry
    // its own badge look; empty falls back to DEFAULT_ACCENT.
    mapping(uint256 => string) public jurisdictionAccentColor;

    event JurisdictionPtsMinted(
        uint256 indexed jurisdictionId,
        address indexed recipient,
        uint256 amount,
        uint256 indexed controllerVoteTokenId,
        uint256 recipientVoteTokenId,
        address operator,
        bytes32 contextHash
    );

    event JurisdictionPtsBurned(
        uint256 indexed jurisdictionId,
        address indexed source,
        uint256 amount,
        uint256 indexed controllerVoteTokenId,
        uint256 sourceVoteTokenId,
        address operator,
        bytes32 contextHash
    );

    event JurisdictionConfigured(
        uint256 indexed jurisdictionId,
        address indexed governor,
        address indexed bootstrapOperator
    );

    event JurisdictionGovernorUpdated(
        uint256 indexed jurisdictionId,
        address indexed previousGovernor,
        address indexed newGovernor
    );

    event JurisdictionOperatorUpdated(
        uint256 indexed jurisdictionId,
        address indexed operator,
        bool allowed,
        address actor
    );

    event RoleCatalogUpdated(address indexed catalog);

    event JurisdictionAccentColorUpdated(uint256 indexed jurisdictionId, string accentColor, address actor);

    error NonTransferable();

    constructor(address admin, address voteTokenAddress, string memory baseUri) ERC1155(baseUri) {
        require(admin != address(0), "JurisdictionPts1155Bank: admin required");
        require(voteTokenAddress != address(0), "JurisdictionPts1155Bank: vote token required");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BANK_OPERATOR_ROLE, admin);
        _grantRole(JURISDICTION_FACTORY_ROLE, admin);

        voteToken721 = IERC721(voteTokenAddress);
        voteToken = IVoteTokenJurisdictionView(voteTokenAddress);
    }

    function configureJurisdiction(
        uint256 jurisdictionId,
        address governor,
        address bootstrapOperator
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _configureJurisdiction(jurisdictionId, governor, bootstrapOperator);
    }

    function bootstrapJurisdictionFromFactory(
        uint256 jurisdictionId,
        address governor,
        address bootstrapOperator
    ) external onlyRole(JURISDICTION_FACTORY_ROLE) {
        _configureJurisdiction(jurisdictionId, governor, bootstrapOperator);
    }

    function setJurisdictionGovernor(uint256 jurisdictionId, address newGovernor) external {
        require(jurisdictionConfigured[jurisdictionId], "JurisdictionPts1155Bank: jurisdiction not configured");
        require(newGovernor != address(0), "JurisdictionPts1155Bank: invalid governor");
        require(
            hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) || _msgSender() == jurisdictionGovernors[jurisdictionId],
            "JurisdictionPts1155Bank: governor only"
        );

        address previousGovernor = jurisdictionGovernors[jurisdictionId];
        jurisdictionGovernors[jurisdictionId] = newGovernor;
        _jurisdictionOperators[jurisdictionId][newGovernor] = true;

        emit JurisdictionGovernorUpdated(jurisdictionId, previousGovernor, newGovernor);
        emit JurisdictionOperatorUpdated(jurisdictionId, newGovernor, true, _msgSender());
    }

    function setJurisdictionOperator(uint256 jurisdictionId, address operator, bool allowed) external {
        require(jurisdictionConfigured[jurisdictionId], "JurisdictionPts1155Bank: jurisdiction not configured");
        require(operator != address(0), "JurisdictionPts1155Bank: invalid operator");
        require(
            hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) || _msgSender() == jurisdictionGovernors[jurisdictionId],
            "JurisdictionPts1155Bank: governor only"
        );

        _jurisdictionOperators[jurisdictionId][operator] = allowed;
        emit JurisdictionOperatorUpdated(jurisdictionId, operator, allowed, _msgSender());
    }

    function isJurisdictionOperator(uint256 jurisdictionId, address operator) public view returns (bool) {
        return _jurisdictionOperators[jurisdictionId][operator];
    }

    function setRoleCatalog(address catalogAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        roleCatalog = catalogAddress;
        emit RoleCatalogUpdated(catalogAddress);
    }

    /// @notice Set the accent color used to render this jurisdiction's on-chain PTS badge
    ///         SVG. Same per-jurisdiction authority as operators (governor or admin).
    function setJurisdictionAccentColor(uint256 jurisdictionId, string calldata accentColor) external {
        require(jurisdictionConfigured[jurisdictionId], "JurisdictionPts1155Bank: jurisdiction not configured");
        require(
            hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) || _msgSender() == jurisdictionGovernors[jurisdictionId],
            "JurisdictionPts1155Bank: governor only"
        );

        jurisdictionAccentColor[jurisdictionId] = accentColor;
        emit JurisdictionAccentColorUpdated(jurisdictionId, accentColor, _msgSender());
    }

    function mintFromControllerToken(
        address to,
        uint256 jurisdictionId,
        uint256 amount,
        uint256 controllerVoteTokenId,
        uint256 recipientVoteTokenId,
        bytes32 contextHash
    ) external {
        require(to != address(0), "JurisdictionPts1155Bank: invalid recipient");
        require(jurisdictionId > 0, "JurisdictionPts1155Bank: jurisdiction required");
        require(amount > 0, "JurisdictionPts1155Bank: amount required");
        _requireJurisdictionOperator(jurisdictionId);

        _assertVoteTokenBinding(controllerVoteTokenId, voteToken721.ownerOf(controllerVoteTokenId), jurisdictionId);
        _assertVoteTokenBinding(recipientVoteTokenId, to, jurisdictionId);

        _mint(to, jurisdictionId, amount, "");

        emit JurisdictionPtsMinted(
            jurisdictionId,
            to,
            amount,
            controllerVoteTokenId,
            recipientVoteTokenId,
            _msgSender(),
            contextHash
        );
    }

    /**
     * @notice Mint jurisdiction PTS to a wallet that is not required to hold a VoteToken.
     *         The controller remains an active jurisdiction voter and the caller remains an
     *         authorized jurisdiction operator. A VoteToken is citizenship; PTS is currency,
     *         and vendors/laborers may hold currency without joining the electorate.
     * @dev Emits the existing event with recipientVoteTokenId=0 for ABI/indexer continuity.
     */
    function mintToWallet(
        address to,
        uint256 jurisdictionId,
        uint256 amount,
        uint256 controllerVoteTokenId,
        bytes32 contextHash
    ) external {
        require(to != address(0), "JurisdictionPts1155Bank: invalid recipient");
        require(jurisdictionId > 0, "JurisdictionPts1155Bank: jurisdiction required");
        require(amount > 0, "JurisdictionPts1155Bank: amount required");
        require(contextHash != bytes32(0), "JurisdictionPts1155Bank: context required");
        require(!processedWalletContexts[contextHash], "JurisdictionPts1155Bank: context already processed");
        _requireJurisdictionOperator(jurisdictionId);

        _assertVoteTokenBinding(controllerVoteTokenId, voteToken721.ownerOf(controllerVoteTokenId), jurisdictionId);
        processedWalletContexts[contextHash] = true;
        _mint(to, jurisdictionId, amount, "");

        emit JurisdictionPtsMinted(
            jurisdictionId,
            to,
            amount,
            controllerVoteTokenId,
            0,
            _msgSender(),
            contextHash
        );
    }

    function burnFromControllerToken(
        address from,
        uint256 jurisdictionId,
        uint256 amount,
        uint256 controllerVoteTokenId,
        uint256 sourceVoteTokenId,
        bytes32 contextHash
    ) external {
        require(from != address(0), "JurisdictionPts1155Bank: invalid source");
        require(jurisdictionId > 0, "JurisdictionPts1155Bank: jurisdiction required");
        require(amount > 0, "JurisdictionPts1155Bank: amount required");
        _requireJurisdictionOperator(jurisdictionId);

        _assertVoteTokenBinding(controllerVoteTokenId, voteToken721.ownerOf(controllerVoteTokenId), jurisdictionId);
        _assertVoteTokenBinding(sourceVoteTokenId, from, jurisdictionId);

        _burn(from, jurisdictionId, amount);

        emit JurisdictionPtsBurned(
            jurisdictionId,
            from,
            amount,
            controllerVoteTokenId,
            sourceVoteTokenId,
            _msgSender(),
            contextHash
        );
    }

    /**
     * @notice Burn jurisdiction PTS from a wallet without requiring that wallet to hold a
     *         VoteToken. The authorized operator + active controller VoteToken remain the
     *         accountable settlement authority.
     * @dev Emits the existing event with sourceVoteTokenId=0 for ABI/indexer continuity.
     */
    function burnFromWallet(
        address from,
        uint256 jurisdictionId,
        uint256 amount,
        uint256 controllerVoteTokenId,
        bytes32 contextHash
    ) external {
        require(from != address(0), "JurisdictionPts1155Bank: invalid source");
        require(jurisdictionId > 0, "JurisdictionPts1155Bank: jurisdiction required");
        require(amount > 0, "JurisdictionPts1155Bank: amount required");
        require(contextHash != bytes32(0), "JurisdictionPts1155Bank: context required");
        require(!processedWalletContexts[contextHash], "JurisdictionPts1155Bank: context already processed");
        _requireJurisdictionOperator(jurisdictionId);

        _assertVoteTokenBinding(controllerVoteTokenId, voteToken721.ownerOf(controllerVoteTokenId), jurisdictionId);
        processedWalletContexts[contextHash] = true;
        _burn(from, jurisdictionId, amount);

        emit JurisdictionPtsBurned(
            jurisdictionId,
            from,
            amount,
            controllerVoteTokenId,
            0,
            _msgSender(),
            contextHash
        );
    }

    function _assertVoteTokenBinding(uint256 tokenId, address expectedOwner, uint256 jurisdictionId) private view {
        require(tokenId > 0, "JurisdictionPts1155Bank: vote token required");
        require(expectedOwner != address(0), "JurisdictionPts1155Bank: invalid token owner");
        require(voteToken.isActive(tokenId), "JurisdictionPts1155Bank: vote token inactive");
        require(voteToken.jurisdictionIdOf(tokenId) == jurisdictionId, "JurisdictionPts1155Bank: jurisdiction mismatch");
        require(voteToken721.ownerOf(tokenId) == expectedOwner, "JurisdictionPts1155Bank: token owner mismatch");
    }

    function _configureJurisdiction(uint256 jurisdictionId, address governor, address bootstrapOperator) private {
        require(jurisdictionId > 0, "JurisdictionPts1155Bank: jurisdiction required");
        require(!jurisdictionConfigured[jurisdictionId], "JurisdictionPts1155Bank: jurisdiction already configured");
        require(governor != address(0), "JurisdictionPts1155Bank: governor required");

        jurisdictionConfigured[jurisdictionId] = true;
        jurisdictionGovernors[jurisdictionId] = governor;
        _jurisdictionOperators[jurisdictionId][governor] = true;

        if (bootstrapOperator != address(0)) {
            _jurisdictionOperators[jurisdictionId][bootstrapOperator] = true;
        }

        emit JurisdictionConfigured(jurisdictionId, governor, bootstrapOperator);
        emit JurisdictionOperatorUpdated(jurisdictionId, governor, true, _msgSender());
        if (bootstrapOperator != address(0)) {
            emit JurisdictionOperatorUpdated(jurisdictionId, bootstrapOperator, true, _msgSender());
        }
    }

    function _requireJurisdictionOperator(uint256 jurisdictionId) private view {
        require(jurisdictionConfigured[jurisdictionId], "JurisdictionPts1155Bank: jurisdiction not configured");
        require(
            hasRole(BANK_OPERATOR_ROLE, _msgSender()) ||
            _jurisdictionOperators[jurisdictionId][_msgSender()],
            "JurisdictionPts1155Bank: sender not jurisdiction operator"
        );
    }

    // ---------------------------------------------------------------------
    // On-chain metadata (fully self-contained data: URI — no server, no IPFS)
    // ---------------------------------------------------------------------

    /// @notice Collection-level name, for wallets/explorers that show one label for the
    ///         whole 1155 contract (per-token names come from uri()).
    function name() external pure returns (string memory) {
        return "Jurisdiction PTS";
    }

    function symbol() external pure returns (string memory) {
        return "JPTS";
    }

    /**
     * @notice ERC-1155 metadata rendered entirely on-chain as a base64 data URI — a PTS
     *         badge named after the jurisdiction ("<Jurisdiction Name> PTS"), mirroring
     *         VoteToken.tokenURI's on-chain badge so both token families read consistently
     *         in wallets/explorers even if every backend is offline.
     */
    function uri(uint256 jurisdictionId) public view override returns (string memory) {
        string memory jName = _jurisdictionLabel(jurisdictionId);
        string memory accent = _accentColor(jurisdictionId);
        string memory id = jurisdictionId.toString();

        string memory json = string.concat(
            '{"name":"', jName, ' PTS","description":"Jurisdiction-scoped participation points on the Real Democracy network (built by the JUX Foundation). Non-transferable, held in the JurisdictionPts1155Bank.",',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(_renderSVG(jName, id, accent))), '",',
            '"attributes":[{"trait_type":"Jurisdiction","value":"', jName, '"},{"trait_type":"Jurisdiction Id","value":"', id, '"}]}'
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

    /// @dev Per-jurisdiction accent, falling back to DEFAULT_ACCENT when unset.
    function _accentColor(uint256 jurisdictionId) private view returns (string memory) {
        string memory set = jurisdictionAccentColor[jurisdictionId];
        return bytes(set).length > 0 ? set : DEFAULT_ACCENT;
    }

    /// @dev PTS coin-card SVG, sibling to VoteToken's badge: same fist emblem + accent, its
    ///      own "<Jurisdiction> PTS" wordmark in place of role/state pills.
    function _renderSVG(string memory jName, string memory id, string memory accent)
        private
        pure
        returns (string memory)
    {
        string memory head = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' width='500' height='500' viewBox='0 0 500 500'><defs>",
            "<radialGradient id='bg' cx='18%' cy='14%' r='90%'><stop offset='0%' stop-color='#111830'/><stop offset='55%' stop-color='#060812'/><stop offset='100%' stop-color='#04060f'/></radialGradient>",
            "<linearGradient id='ring' x1='0' y1='0' x2='1' y2='1'><stop offset='0%' stop-color='#ffffff' stop-opacity='0.6'/><stop offset='45%' stop-color='", accent, "'/><stop offset='100%' stop-color='", accent, "' stop-opacity='0.5'/></linearGradient>",
            "<radialGradient id='glow' cx='50%' cy='50%' r='50%'><stop offset='0%' stop-color='", accent, "' stop-opacity='0.35'/><stop offset='100%' stop-color='", accent, "' stop-opacity='0'/></radialGradient></defs>"
        );
        string memory coin = string.concat(
            "<rect width='500' height='500' rx='28' fill='url(#bg)'/>",
            "<rect x='10' y='10' width='480' height='480' rx='24' fill='none' stroke='url(#ring)' stroke-width='2' opacity='0.6'/>",
            "<circle cx='250' cy='188' r='148' fill='url(#glow)'/>",
            "<circle cx='250' cy='188' r='116' fill='#0a0e1c' stroke='url(#ring)' stroke-width='6'/>",
            "<circle cx='250' cy='188' r='102' fill='none' stroke='#ffffff' stroke-opacity='0.12' stroke-width='1.5'/>",
            "<g transform='translate(202.8,115) scale(0.0286)' fill='", accent, "'><path fill-rule='evenodd' d='", FistArt.PATH, "'/></g>"
        );
        string memory text = string.concat(
            "<text x='250' y='350' text-anchor='middle' fill='#ffffff' font-family='Helvetica,Arial,sans-serif' font-size='32' font-weight='bold'>", jName, "</text>",
            "<text x='250' y='378' text-anchor='middle' fill='#ffffff' fill-opacity='0.55' font-family='Helvetica,Arial,sans-serif' font-size='15' letter-spacing='1'>PTS &#183; Jurisdiction #", id, "</text>"
        );
        return string.concat(head, coin, text, "</svg>");
    }

    function setApprovalForAll(address, bool) public pure override {
        revert NonTransferable();
    }

    function safeTransferFrom(address, address, uint256, uint256, bytes memory) public pure override {
        revert NonTransferable();
    }

    function safeBatchTransferFrom(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        pure
        override
    {
        revert NonTransferable();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
