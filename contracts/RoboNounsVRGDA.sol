// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import { IRoboNounsSeeder } from "contracts/interfaces/IRoboNounsSeeder.sol";
import { IRoboNounsDescriptor } from "contracts/interfaces/IRoboNounsDescriptor.sol";
import { IRoboNounsVRGDA } from "contracts/interfaces/IRoboNounsVRGDA.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { VRGDA } from "contracts/lib/VRGDA.sol";
import { RoboNounsToken } from "contracts/RoboNounsToken.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { toWadUnsafe, toDaysWadUnsafe, wadLn } from "solmate/src/utils/SignedWadMath.sol";

contract RoboNounsVRGDA is IRoboNounsVRGDA, PausableUpgradeable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
    /// @notice The very next nounID that will be minted on auction,
    /// equal to total number sold + 1
    uint256 public nextNounId = 0;

    /// @notice Time of sale of the first RoboNoun, used to calculate VRGDA price
    uint256 public startTime;

    /// @notice How often the VRGDA price will update to reflect VRGDA pricing rules
    uint256 public updateInterval = 15 minutes;

    /// @notice The minimum price accepted in an auction
    uint256 public reservePrice;

    /// @notice The WETH contract address
    address public weth;

    /// @notice The address of the auction house contract to be replaced
    /// @dev Used to track which token ID to the VRGDA auction start at
    address internal oldAuctionHouseAddress;

    /// @notice The Nouns ERC721 token contract
    RoboNounsToken public roboNounstoken;

    /// @notice Target price for a token, to be scaled according to sales pace.
    /// @dev Represented as an 18 decimal fixed point number.
    int256 public targetPrice;

    /// @dev Precomputed constant that allows us to rewrite a pow() as an exp().
    /// @dev Represented as an 18 decimal fixed point number.
    int256 public decayConstant;

    /// @dev The total number of tokens to target selling every full unit of time.
    /// @dev Represented as an 18 decimal fixed point number.
    int256 public perTimeUnit;

    function initialize(
        int256 _targetPrice,
        int256 _priceDecayPercent,
        int256 _perTimeUnit,
        uint256 _startTime,
        address _roboNounstokenAddress
    ) external initializer {
        __Pausable_init();
        __ReentrancyGuard_init();
        __Ownable_init();

        _pause();

        roboNounstoken = RoboNounsToken(_roboNounstokenAddress);
        oldAuctionHouseAddress = address(roboNounstoken.minter());
        startTime = _startTime;
        targetPrice = _targetPrice;
        decayConstant = wadLn(1e18 - _priceDecayPercent);
        require(decayConstant < 0, "NON_NEGATIVE_DECAY_CONSTANT");

        perTimeUnit = _perTimeUnit;
    }

    /// @notice Settle the auction
    /// @param expectedBlockNumber The parent blockhash expected when
    /// transaction executes
    function settleAuction(uint256 expectedBlockNumber) external payable override whenNotPaused nonReentrant {
        // will allow to mint token with traits generated from 4 last blocks,
        // block.number wouldn't work regardless, so not validated here
        require(expectedBlockNumber >= block.number - 4, "Invalid block number");
        uint256 _nextNounIdForCaller = nextNounIdForCaller();
        require(msg.value >= reservePrice, "Below reservePrice");

        // Validate the purchase request against the VRGDA rules.
        uint256 price = getCurrentVRGDAPrice();
        require(msg.value >= price, "Insufficient funds");

        // Call settleAuction on the roboNouns contract.
        uint256 mintedNounId = roboNounstoken.mint(expectedBlockNumber);
        assert(mintedNounId == _nextNounIdForCaller);

        // Sends token to caller.
        roboNounstoken.transferFrom(address(this), msg.sender, mintedNounId);

        // Sends the funds to the DAO. // removed for mumbai testing purposes
        // if (msg.value > 0) {
        //     uint256 refundAmount = msg.value - price;
        //     if (refundAmount > 0) {
        //         _safeTransferETHWithFallback(msg.sender, refundAmount);
        //     }
        //     if (price > 0) {
        //         _safeTransferETHWithFallback(nounsDAO, price);
        //     }
        // }

        nextNounId = mintedNounId + 1;
        emit AuctionSettled(mintedNounId, msg.sender, price);
    }

    /// @notice Set the auction reserve price.
    /// @dev Only callable by the owner.
    function setReservePrice(uint256 _reservePrice) external onlyOwner {
        reservePrice = _reservePrice;

        emit AuctionReservePriceUpdated(_reservePrice);
    }

    /// @notice Set the auction update interval.
    /// @dev Only callable by the owner.
    function setUpdateInterval(uint256 _updateInterval) external onlyOwner {
        updateInterval = _updateInterval;

        emit AuctionUpdateIntervalUpdated(_updateInterval);
    }

    /// @notice Set the auction target price.
    /// @dev Only callable by the owner.
    function setTargetPrice(int256 _targetPrice) external onlyOwner {
        targetPrice = _targetPrice;

        emit AuctionTargetPriceUpdated(_targetPrice);
    }

    /// @notice Set the auction price decay percent.
    /// @dev Only callable by the owner.
    function setPriceDecayPercent(int256 _priceDecayPercent) external onlyOwner {
        decayConstant = wadLn(1e18 - _priceDecayPercent);
        require(decayConstant < 0, "NON_NEGATIVE_DECAY_CONSTANT");

        emit AuctionPriceDecayPercentUpdated(_priceDecayPercent);
    }

    /// @notice Set the auction per time unit.
    /// @dev Only callable by the owner.
    function setPerTimeUnit(int256 _perTimeUnit) external onlyOwner {
        perTimeUnit = _perTimeUnit;

        emit AuctionPerTimeUnitUpdated(_perTimeUnit);
    }

    /// @notice Pause the RoboNouns auction.
    /// @dev This function can only be called by the owner when the contract is unpaused.
    /// No new auctions can be started when paused.
    function pause() external override onlyOwner {
        _pause();
    }

    /// @notice Unpause the RoboNouns auction.
    /// @dev This function can only be called by the owner when the contract is paused.
    function unpause() external override onlyOwner {
        _unpause();
    }

    /// @notice Fetch data associated with the noun for sale
    /// @dev This function should be called using the `pending` block tag.
    /// @dev The nounId and hash should passed as arguments to the `settleAuction` function.
    /// @return nounId The nounId that will be minted
    /// @return seed The seed containing the noun attributes
    /// @return svg The SVG image of the the noun
    /// @return price The price of the noun in Wei
    /// @return hash The expected parent blockhash for this noun
    function fetchNextNoun()
        external
        view
        override
        returns (uint256 nounId, IRoboNounsSeeder.Seed memory seed, string memory svg, uint256 price, bytes32 hash)
    {
        uint256 _nextNounIdForCaller = nextNounIdForCaller();
        // Generate the seed for the next noun.
        IRoboNounsSeeder seeder = IRoboNounsSeeder(roboNounstoken.seeder());
        IRoboNounsDescriptor descriptor = IRoboNounsDescriptor(roboNounstoken.descriptor());
        seed = seeder.generateSeed(_nextNounIdForCaller, descriptor, block.number - 1);

        // Generate the SVG from seed using the descriptor.
        svg = descriptor.generateSVGImage(seed);

        // Calculate price based on VRGDA rules.
        uint256 vrgdaPrice = getCurrentVRGDAPrice();
        price = vrgdaPrice > reservePrice ? vrgdaPrice : reservePrice;

        // Fetch the blockhash associated with this noun.
        hash = blockhash(block.number - 1);

        return (_nextNounIdForCaller, seed, svg, price, hash);
    }

    /// @notice Get the current price according to the VRGDA rules.
    /// @return price The current price in Wei
    function getCurrentVRGDAPrice() public view returns (uint256) {
        uint256 absoluteTimeSinceStart = block.timestamp - startTime;
        return
            VRGDA.getVRGDAPrice(
                toDaysWadUnsafe(absoluteTimeSinceStart - (absoluteTimeSinceStart % updateInterval)),
                targetPrice,
                decayConstant,
                // Theoretically calling toWadUnsafe with sold can silently overflow but under
                // any reasonable circumstance it will never be large enough. We use sold + 1 as
                // the VRGDA formula's n param represents the nth token and sold is the n-1th token.
                VRGDA.getTargetSaleTimeLinear(toWadUnsafe(nextNounId + 1), perTimeUnit)
            );
    }

    /// @notice Get the next nounId that would be minted for the caller (skips over reserved roboNouns)
    /// @dev handles edge case in roboNouns token contract
    /// @return The next nounId that would be minted for the caller
    function nextNounIdForCaller() public view returns (uint256) {
        // Calculate nounId that would be minted to the caller
        uint256 _nextNounIdForCaller = nextNounId;
        if (_nextNounIdForCaller <= 175300 && _nextNounIdForCaller % 10 == 0) {
            _nextNounIdForCaller++;
        }
        if (_nextNounIdForCaller <= 175301 && _nextNounIdForCaller % 10 == 1) {
            _nextNounIdForCaller++;
        }
        return _nextNounIdForCaller;
    }

    /// @notice Transfer ETH. If the ETH transfer fails, wrap the ETH and try send it as weth.
    function _safeTransferETHWithFallback(address to, uint256 amount) internal {
        if (!_safeTransferETH(to, amount)) {
            IWETH(weth).deposit{ value: amount }();
            IERC20(weth).transfer(to, amount);
        }
    }

    /// @notice Transfer ETH and return the success status.
    /// @dev This function only forwards 30,000 gas to the callee.
    function _safeTransferETH(address to, uint256 value) internal returns (bool) {
        (bool success, ) = to.call{ value: value, gas: 30_000 }(new bytes(0));
        return success;
    }
}
