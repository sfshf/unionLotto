// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "hardhat/console.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IRandomNumberGenerator.sol";

contract UnionLotto is ReentrancyGuard, Ownable(msg.sender) {
    using SafeERC20 for IERC20;

    // percentage of the pool to be paid to treasury
    uint256 public treasuryFee = 1;
    address public treasuryAddress;

    uint256 public ticketPrice = 2 ether;

    IERC20 public usdToken;
    IRandomNumberGenerator public randomGenerator;
    uint256 public closeBlockNumber = 0;
    uint256 public requestRandomnessBlockNumber = 0;

    // Unclaimed ticket prize pool will be added to the jackpot.
    // The jackpot will be distributed to the first prize winner.
    uint256 public jackpotAmount = 0;

    struct Ticket {
        // ticket number: 6 number from 1 to 66. Every number can be used only once, and number is sorted in ascending order
        uint224 number;
        /// bracket => number of matched digits, 0 means hit 1 number, 5 means hit 6 numbers
        uint32 bracket;
        address owner;
    }
    /// @notice mapping ticketId => tickets
    mapping(uint256 => Ticket) private _tickets;
    uint256 public currentTicketId = 0;
    uint256 public lotteryLength = 5 days;
    uint256 public rewardingLength = 2 days - 4 hours;

    enum Status {
        Pending,
        Open,
        Close,
        Claimable
    }

    Status public status = Status.Pending;
    // start selling tickets
    uint256 public startTime;
    // end selling tickets
    uint256 public endTime;
    // uses must claim their prizes before this time
    uint256 public endRewardTime;
    // rewardsBreakdown[0] means the total reward percentage for all tickets hit 1 number, 5 means the ticket hit 6 numbers
    uint256[6] public rewardsBreakdown = [0, 15, 15, 15, 15, 40];
    // rewardsForBracket[0] means the reward amount for one ticket hit 1 number, 5 means the reward amount for one ticket hit 6 numbers
    uint256[6] public rewardsForBracket = [0, 0, 0, 0, 0, 0];
    uint256 public finalNumber = 0;

    // plan for the next lottery
    event LotterySet(uint256 indexed startTime);
    event LotteryDrawn(
        uint256 indexed startTime,
        uint256 finalNumber,
        // first prize winner
        uint256 countWinningTickets
    );
    event NewTreasuryAddress(address indexed treasury);
    event NewRandomGenerator(address indexed randomGenerator);
    event TicketsPurchase(address indexed buyer, uint256 numberTickets);
    event TicketsClaim(address indexed claimer, uint256 amount);

    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    constructor(
        address _usdTokenAddress,
        address _randomGeneratorAddress,
        address _treasuryAddress
    ) {
        usdToken = IERC20(_usdTokenAddress);
        randomGenerator = IRandomNumberGenerator(_randomGeneratorAddress);
        treasuryAddress = _treasuryAddress;
    }

    // 设置庄家地址
    function setTreasuryAddresses(address _treasuryAddress) external onlyOwner {
        treasuryAddress = _treasuryAddress;
        emit NewTreasuryAddress(_treasuryAddress);
    }

    // 设置随机数生成器地址
    function setRandomGenerator(
        address _randomGeneratorAddress
    ) external onlyOwner {
        randomGenerator = IRandomNumberGenerator(_randomGeneratorAddress);
        emit NewRandomGenerator(_randomGeneratorAddress);
    }

    // 设置ERC20币地址
    function setUSDToken(address _usdTokenAddress) external onlyOwner {
        usdToken = IERC20(_usdTokenAddress);
    }

    // 设置庄家手续费百分比
    function setTreasuryFee(uint256 _treasuryFee) external onlyOwner {
        treasuryFee = _treasuryFee;
    }

    // 设置票价
    function setTicketPrice(uint256 _ticketPrice) external onlyOwner {
        ticketPrice = _ticketPrice;
    }

    // 设置兑奖比例
    function setRewardsBreakdown(
        uint256[6] memory _rewardsBreakdown
    ) external onlyOwner {
        require(status == Status.Pending, "Can't change rewards now");
        rewardsBreakdown = _rewardsBreakdown;
    }

    // 重开新一轮彩票
    function resetForNewLottery(
        uint256 _startTime,
        uint256 _endTime
    ) external onlyOwner {
        if (status == Status.Claimable) {
            require(
                block.timestamp > endRewardTime,
                "Cannot reset before endRewardTime"
            );
        }
        require(
            _startTime != 0 || _endTime != 0,
            "Cannot reset with 0 startTime and endTime"
        );
        if (_endTime != 0) {
            _startTime = _endTime - lotteryLength;
        }
        require(
            _startTime > block.timestamp,
            "Cannot start with startTime in the past"
        );

        status = Status.Pending;
        startTime = _startTime;
        endTime = _startTime + lotteryLength;
        endRewardTime = endTime + rewardingLength;
        currentTicketId = 0;
        jackpotAmount = usdToken.balanceOf(address(this));
        emit LotterySet(startTime);
    }

    // 开始售卖彩票
    function startLottery() external notContract {
        require(status == Status.Pending, "Lottery already started");
        require(
            startTime <= block.timestamp,
            "Cannot start lottery before startTime"
        );
        status = Status.Open;
    }

    // 停止售卖彩票
    function closeLottery() external notContract {
        require(
            endTime <= block.timestamp,
            "Cannot close lottery before endTime"
        );
        require(status == Status.Open, "Lottery not open");
        status = Status.Close;
        closeBlockNumber = block.number;
    }

    // draw lottery: frist, request randomness from randomGenerator
    // 摇奖：第一步，向随机数生成器请求随机数
    function requestRandomness(
        uint256 seedHash
    ) external notContract onlyOwner {
        require(status == Status.Close, "Lottery not closed");
        require(
            endRewardTime > block.timestamp,
            "Cannot draw lottery after endRewardTime"
        );
        require(
            block.number != closeBlockNumber,
            "requestRandomness cannot be called in the same block as closeLottery"
        );
        requestRandomnessBlockNumber = block.number;
        randomGenerator.requestRandomValue(seedHash);
    }

    // draw lottery: second, reveal randomness from randomGenerator
    // 摇奖：第二步，向随机数生成器请求揭示随机数
    function revealRandomness(uint256 seed) external notContract onlyOwner {
        require(status == Status.Close, "Lottery not closed");
        require(
            endRewardTime > block.timestamp,
            "Cannot draw lottery after endRewardTime"
        );
        require(
            block.number != requestRandomnessBlockNumber,
            "revealRandomness cannot be called in the same block as requestRandomness"
        );
        status = Status.Claimable;

        // calculate the finalNumber from randomResult
        uint256 randomNumber = randomGenerator.revealRandomValue(seed);
        finalNumber = getRandomTicketNumber(randomNumber);

        drawLottery();
    }

    // draw lottery: third, calculate the winning tickets
    // 摇奖：第三步，核算胜出票
    function drawLottery() private {
        uint256[] memory countWinningTickets = new uint256[](6);
        for (uint256 i = 0; i < currentTicketId; i++) {
            Ticket storage ticket = _tickets[i];
            uint256 winningNumber = finalNumber;
            uint256 userNumber = ticket.number;
            uint32 matchedDigits = 0;
            for (uint256 index = 0; index < 6; index++) {
                if (winningNumber % 66 == userNumber % 66) {
                    matchedDigits++;
                }
                winningNumber /= 66;
                userNumber /= 66;
            }
            if (matchedDigits > 0) {
                ticket.bracket = matchedDigits - 1;
                countWinningTickets[matchedDigits - 1]++;
            } else {
                delete _tickets[i];
            }
        }
        // calculate the prize pool
        uint256 prizePool = usdToken.balanceOf(address(this)) - jackpotAmount;
        uint256 fee = (prizePool * treasuryFee) / 100;
        usdToken.transfer(treasuryAddress, fee);
        prizePool -= fee;
        for (uint256 index = 0; index < 5; index++) {
            uint256 countingForBrackets = countWinningTickets[index];
            if (countingForBrackets != 0) {
                rewardsForBracket[index] =
                    (prizePool * rewardsBreakdown[index]) /
                    100 /
                    countingForBrackets;
            }
        }
        // the last bracket is the jackpot
        if (countWinningTickets[5] != 0) {
            rewardsForBracket[5] =
                (jackpotAmount + (prizePool * rewardsBreakdown[5]) / 100) /
                countWinningTickets[5];
        }
        emit LotteryDrawn(startTime, finalNumber, countWinningTickets[5]);
    }

    // 购买彩票
    function buyTickets(
        uint256[] calldata _ticketNumbers
    ) external notContract nonReentrant {
        require(status == Status.Open, "Lottery not open");
        require(block.timestamp < endTime, "Cannot buy tickets after endTime");
        require(_ticketNumbers.length > 0, "Cannot buy 0 tickets");
        uint256 totalCost = _ticketNumbers.length * ticketPrice;
        require(
            usdToken.balanceOf(msg.sender) >= totalCost,
            "Not enough USD to buy ticket"
        );
        usdToken.safeTransferFrom(msg.sender, address(this), totalCost);
        for (uint256 i = 0; i < _ticketNumbers.length; i++) {
            _tickets[currentTicketId++] = Ticket({
                number: uint224(_ticketNumbers[i]),
                bracket: 0,
                owner: msg.sender
            });
        }

        emit TicketsPurchase(msg.sender, _ticketNumbers.length);
    }

    // 认领彩票
    function claimTickets(
        uint256[] calldata _ticketIds
    ) external notContract nonReentrant {
        require(status == Status.Claimable, "Lottery not claimable");
        require(_ticketIds.length > 0, "Cannot claim 0 tickets");
        require(
            block.timestamp < endRewardTime,
            "Cannot claim tickets after endRewardTime"
        );

        uint256 reward = 0;
        for (uint256 i = 0; i < _ticketIds.length; i++) {
            uint256 ticketId = _ticketIds[i];
            require(ticketId < currentTicketId, "Invalid ticketId");
            require(
                _tickets[ticketId].owner == msg.sender,
                "Not the owner of the ticket"
            );

            reward += rewardsForBracket[_tickets[ticketId].bracket];

            delete _tickets[_ticketIds[i]];
        }
        require(reward > 0, "No reward");

        usdToken.safeTransfer(msg.sender, reward);
        emit TicketsClaim(msg.sender, reward);
    }

    // 查看彩票号码
    function viewTicketNumber(
        uint256 number
    ) public pure returns (uint32[] memory) {
        uint32[] memory ticketNumbers = new uint32[](6);
        for (uint256 index = 0; index < 6; index++) {
            ticketNumbers[index] = uint32(number % 66) + 1;
            number /= 66;
        }
        return ticketNumbers;
    }

    // 查看彩票结果
    function viewResult() external view returns (uint32[] memory) {
        require(status == Status.Claimable, "Lottery not claimable");
        return viewTicketNumber(finalNumber);
    }

    // 查看彩票信息
    function viewTicket(
        uint256 ticketId
    ) external view returns (uint32[] memory, uint32, address) {
        require(ticketId < currentTicketId, "Invalid ticketId");
        Ticket memory ticket = _tickets[ticketId];
        return (viewTicketNumber(ticket.number), ticket.bracket, ticket.owner);
    }

    // ticket number: 6 number from 1 to 66. Every number can be used only once, and number is sorted in ascending order
    // calculate the ticket number from a random number
    // 获取随机彩票号码
    function getRandomTicketNumber(
        uint256 randomNumber
    ) public pure returns (uint256) {
        uint8[] memory numbers = new uint8[](66);
        uint256 current = 0;
        for (uint256 i = 0; i < 6; i++) {
            current = (current + (randomNumber % (66 - i))) % 66;
            randomNumber /= 256;
            while (numbers[current] != 0) {
                current++;
                if (current >= 66) {
                    current = 0;
                }
            }
            numbers[current] = 1;
        }
        current = 0;
        uint256 index = 66;
        for (uint256 i = 0; i < 6; index--) {
            if (numbers[index - 1] == 1) {
                current = current * 66 + index - 1;
                i++;
                // although i equals 6, the loop will continue to calculate index--, then it will crash..
                // console.log("Index:  %s, i : %s", index - 1, i);
            }
        }
        return current;
    }

    // 查看兑奖比例
    function viewRewardsBreakdown() external view returns (uint256[6] memory) {
        return rewardsBreakdown;
    }

    // 查看奖池金额
    function viewRewardsForBracket() external view returns (uint256[6] memory) {
        return rewardsForBracket;
    }

    // get tickets id list of an address
    // 获取用户的彩票id列表
    function viewTicketsOfAddress(
        address owner
    ) public view returns (uint256[] memory) {
        uint256[] memory ownedTickets = new uint256[](currentTicketId);
        uint256 count = 0;
        for (uint256 i = 0; i < currentTicketId; i++) {
            if (_tickets[i].owner == owner) {
                ownedTickets[count++] = i;
            }
        }
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = ownedTickets[i];
        }
        return result;
    }

    // get claimable tickets id list of an address
    // 获取用户可认领奖金的彩票id列表
    function viewClaimableTicketsOfAddress(
        address owner
    ) public view returns (uint256[] memory) {
        uint256[] memory ownedTickets = viewTicketsOfAddress(owner);
        uint256[] memory claimableTickets = new uint256[](ownedTickets.length);
        uint256 count = 0;
        for (uint256 i = 0; i < ownedTickets.length; i++) {
            uint256 bracket = _tickets[ownedTickets[i]].bracket;
            if (rewardsForBracket[bracket] > 0) {
                claimableTickets[count++] = ownedTickets[i];
            }
        }
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = claimableTickets[i];
        }
        return result;
    }

    // 获取彩票id列表中可认领的奖金总计额
    function viewRewardsAmount(
        uint256[] memory _ticketIds
    ) public view returns (uint256) {
        if (status != Status.Claimable || _ticketIds.length == 0) {
            return 0;
        }
        uint256 reward = 0;
        for (uint256 i = 0; i < _ticketIds.length; i++) {
            reward += rewardsForBracket[_tickets[_ticketIds[i]].bracket];
        }
        return reward;
    }

    // 获取用户可认领奖金的总计额
    function viewMyRewardsAmount() external view returns (uint256) {
        return viewRewardsAmount(viewClaimableTicketsOfAddress(msg.sender));
    }

    /**
     * @notice Check if an address is a contract
     *
     * 判断地址是否为合约地址
     */
    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    // these function should be deleted. Now they are used for testing
    function setEndTime(uint256 _endTime) external onlyOwner {
        endTime = _endTime;
    }

    function setEndRewardTime(uint256 _endRewardTime) external onlyOwner {
        endRewardTime = _endRewardTime;
    }

    function setStartTime(uint256 _startTime) external onlyOwner {
        startTime = _startTime;
    }

    function withdrawAll() external onlyOwner {
        usdToken.transfer(treasuryAddress, usdToken.balanceOf(address(this)));
    }
}
