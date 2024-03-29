pragma solidity ^0.5.16;

import "../Controller/Controller.sol";

contract ControllerScenario is Controller {
    uint public blockNumber;
    address public ucoreAddress;
    address public uaiAddress;

    constructor() public Controller() {}

    function setUCOREAddress(address ucoreAddress_) public {
        ucoreAddress = ucoreAddress_;
    }

    function getUCOREAddress() public view returns (address) {
        return ucoreAddress;
    }

    function setUAIAddress(address uaiAddress_) public {
        uaiAddress = uaiAddress_;
    }

    function getUAIAddress() public view returns (address) {
        return uaiAddress;
    }

    function membershipLength(VToken vToken) public view returns (uint) {
        return accountAssets[address(vToken)].length;
    }

    function fastForward(uint blocks) public returns (uint) {
        blockNumber += blocks;

        return blockNumber;
    }

    function setBlockNumber(uint number) public {
        blockNumber = number;
    }

    function getBlockNumber() public view returns (uint) {
        return blockNumber;
    }

    function getUcoreMarkets() public view returns (address[] memory) {
        uint m = allMarkets.length;
        uint n = 0;
        for (uint i = 0; i < m; i++) {
            if (markets[address(allMarkets[i])].isUcore) {
                n++;
            }
        }

        address[] memory ucoreMarkets = new address[](n);
        uint k = 0;
        for (uint i = 0; i < m; i++) {
            if (markets[address(allMarkets[i])].isUcore) {
                ucoreMarkets[k++] = address(allMarkets[i]);
            }
        }
        return ucoreMarkets;
    }

    function unlist(VToken vToken) public {
        markets[address(vToken)].isListed = false;
    }

    /**
     * @notice Recalculate and update UCORE speeds for all UCORE markets
     */
    function refreshUcoreSpeeds() public {
        VToken[] memory allMarkets_ = allMarkets;

        for (uint i = 0; i < allMarkets_.length; i++) {
            VToken vToken = allMarkets_[i];
            Exp memory borrowIndex = Exp({ mantissa: vToken.borrowIndex() });
            updateUcoreSupplyIndex(address(vToken));
            updateUcoreBorrowIndex(address(vToken), borrowIndex);
        }

        Exp memory totalUtility = Exp({ mantissa: 0 });
        Exp[] memory utilities = new Exp[](allMarkets_.length);
        for (uint i = 0; i < allMarkets_.length; i++) {
            VToken vToken = allMarkets_[i];
            if (ucoreSpeeds[address(vToken)] > 0) {
                Exp memory assetPrice = Exp({ mantissa: oracle.getUnderlyingPrice(vToken) });
                Exp memory utility = mul_(assetPrice, vToken.totalBorrows());
                utilities[i] = utility;
                totalUtility = add_(totalUtility, utility);
            }
        }

        for (uint i = 0; i < allMarkets_.length; i++) {
            VToken vToken = allMarkets[i];
            uint newSpeed = totalUtility.mantissa > 0 ? mul_(ucoreRate, div_(utilities[i], totalUtility)) : 0;
            setUcoreSpeedInternal(vToken, newSpeed, newSpeed);
        }
    }
}
