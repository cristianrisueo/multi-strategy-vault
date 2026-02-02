// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/**
 * @title StrategyManager
 * @author cristianrisueo
 * @notice Cerebro del protocolo que decide allocation y ejecuta rebalancing
 * @dev Usa weighted allocation basado en APY para diversificar entre strategies
 */
contract StrategyManager is Ownable {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    //* Errores

    /**
     * @notice Error cuando no hay estrategias disponibles
     */
    error StrategyManager__NoStrategiesAvailable();

    /**
     * @notice Error cuando se intenta agregar una estrategia duplicada
     */
    error StrategyManager__StrategyAlreadyExists();

    /**
     * @notice Error cuando se intenta remover una estrategia que no existe
     */
    error StrategyManager__StrategyNotFound();

    /**
     * @notice Error cuando el rebalance no es rentable
     */
    error StrategyManager__RebalanceNotProfitable();

    /**
     * @notice Error cuando se intenta operar con cantidad cero
     */
    error StrategyManager__ZeroAmount();

    /**
     * @notice Error cuando solo el vault puede llamar
     */
    error StrategyManager__OnlyVault();

    //* Eventos

    /**
     * @notice Emitido cuando se deposita en una estrategia
     * @param strategy Direccion de la estrategia
     * @param assets Cantidad depositada
     */
    event Allocated(address indexed strategy, uint256 assets);

    /**
     * @notice Emitido cuando se ejecuta un rebalance
     * @param from_strategy Estrategia desde donde se retiran fondos
     * @param to_strategy Estrategia a donde se mueven fondos
     * @param assets Cantidad rebalanceada
     */
    event Rebalanced(address indexed from_strategy, address indexed to_strategy, uint256 assets);

    /**
     * @notice Emitido cuando se agrega una nueva estrategia
     * @param strategy Direccion de la estrategia agregada
     */
    event StrategyAdded(address indexed strategy);

    /**
     * @notice Emitido cuando se remueve una estrategia
     * @param strategy Direccion de la estrategia removida
     */
    event StrategyRemoved(address indexed strategy);

    /**
     * @notice Emitido cuando se recalculan los target allocations. En castellano, porcentajes
     *         de assets que van a cada estrategia
     */
    event TargetAllocationsUpdated();

    //* Variables de estado

    /// @notice Direccion del vault autorizado para llamar allocate/withdraw
    address public immutable vault;

    /// @notice Array de estrategias disponibles
    IStrategy[] public strategies;

    /// @notice Mapeo para verificar rapidamente si una estrategia existe
    mapping(address => bool) public is_strategy;

    /// @notice Target allocation para las estrategias, en basis points (1000 = 10%)
    mapping(IStrategy => uint256) public target_allocation;

    /// @notice Direccion del asset gestionado (WETH)
    address public immutable asset;

    /// @notice Threshold minimo de diferencia de APY para considerar rebalance (2% en basis points)
    uint256 public rebalance_threshold = 200;

    /// @notice TVL minimo para ejecutar rebalance (evita rebalancear cantidades pequeñas)
    uint256 public min_tvl_for_rebalance = 10 ether;

    /// @notice Multiplicador de gas cost usado como margen de seguridad para rebalancear (200 = 2)
    uint256 public gas_cost_multiplier = 200;

    /// @notice Allocation maximo por estrategia en base points (50%)
    uint256 public max_allocation_per_strategy = 5000;

    /// @notice Allocation minimo por estrategia en base points (10%)
    uint256 public min_allocation_threshold = 1000;

    //* Modificadores

    /**
     * @notice Solo permite llamadas del vault
     */
    modifier onlyVault() {
        if (msg.sender != vault) revert StrategyManager__OnlyVault();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor del StrategyManager
     * @dev Inicializa con las direcciones del vault y asset
     * @param _vault Direccion del StrategyVault
     * @param _asset Direccion del asset (WETH)
     */
    constructor(address _vault, address _asset) Ownable(msg.sender) {
        vault = _vault;
        asset = _asset;
    }

    //* Lógica de negocio principal: Depósitos, retiros y rebalances

    /**
     * @notice Deposita assets distribuyendolos segun target allocation
     * @dev Solo puede ser llamado por el vault
     * @dev El vault debe transferir WETH a este manager antes de llamar
     * @param assets Cantidad de WETH a invertir
     */
    function allocate(uint256 assets) external onlyVault {
        // Comprueba que la cantidad a transferir no sea 0 y que existan estrategias disponibles
        if (assets == 0) revert StrategyManager__ZeroAmount();
        if (strategies.length == 0) revert StrategyManager__NoStrategiesAvailable();

        // Calcula target allocations nuevos basados en APYs actuales
        _calculateTargetAllocation();

        // Itera sobre las estrategias disponibles para distribuir los assets según su target allocation
        for (uint256 i = 0; i < strategies.length; i++) {
            // Obtiene el target de la estrategia
            IStrategy strategy = strategies[i];
            uint256 target = target_allocation[strategy];

            // Si la estrategia tiene allocation > 0, deposita proporcionalmente
            if (target > 0) {
                // La fórmula es: (cantidad * target) / 10000
                uint256 amount_for_strategy = (assets * target) / 10000;

                // Transfiere la cantidad correspodiente (un % del total de cantidad) a la estrategia
                // invoca el método para depositar de dicha estrategia y emite un evento de depósito
                if (amount_for_strategy > 0) {
                    IERC20(asset).safeTransfer(address(strategy), amount_for_strategy);
                    strategy.deposit(amount_for_strategy);

                    emit Allocated(address(strategy), amount_for_strategy);
                }
            }
        }
    }

    /**
     * @notice Retira assets del manager hacia el vault
     * @dev Solo puede ser llamado por el vault
     * @dev Retira proporcionalmente de cada estrategia para mantener porcentajes
     *      gracias a que retira proporcionalmente no tenemos que llamar a _calculateTargetAllocation
     *      ahorrando de paso un puto montón de gas, porque los allocations siguen en la misma proporción
     * @param assets Cantidad de WETH a retirar
     * @param receiver Direccion que recibira los assets (normalmente el vault)
     */
    function withdrawTo(uint256 assets, address receiver) external onlyVault {
        // Comprueba que la cantidad a retirar no sea 0. En caso afirmativo revierte
        if (assets == 0) revert StrategyManager__ZeroAmount();

        // Obtiene los assets totales del manager. Si no tiene para la ejecución
        uint256 total_assets = totalAssets();
        if (total_assets == 0) return;

        // Itera sobre cada estrategia para retirar proporcialmente
        for (uint256 i = 0; i < strategies.length; i++) {
            // Obtiene el balance de la estrategia i
            IStrategy strategy = strategies[i];
            uint256 strategy_balance = strategy.totalAssets();

            // Si su balance es 0 omite esta iteración
            if (strategy_balance == 0) continue;

            // Calcula cuanto retirar de esta estrategia (proporcional a su balance)
            uint256 to_withdraw = (assets * strategy_balance) / total_assets;

            // Si el resultado es mayor que 0 invoca el método withdraw de esa estrategia
            if (to_withdraw > 0) {
                strategy.withdraw(to_withdraw);
            }
        }

        // Con el WETH ya en el manager lo transfiere al receiver (vault)
        IERC20(asset).safeTransfer(receiver, assets);
    }

    /**
     * @notice Ejecuta rebalance si es rentable
     * @dev Ajusta cada estrategia a su target allocation moviendo solo los deltas necesarios
     */
    function rebalance() external {
        // Comprueba si es rentable rebalancear
        bool should_rebalance = shouldRebalance();
        if (!should_rebalance) revert StrategyManager__RebalanceNotProfitable();

        // Recalcula targets allocations y obtiene el TVL del protocolo
        // Estas dos líneas obtienen qué porcentaje repartir y cuánto tenemos para repartir
        _calculateTargetAllocation();
        uint256 total_tvl = totalAssets();

        // Arrays vacíos para tracking: Estrategias con exceso de fondos y cuánto exceso tienen
        IStrategy[] memory strategies_with_excess = new IStrategy[](strategies.length);
        uint256[] memory excess_amounts = new uint256[](strategies.length);

        // Arrays vacíos para tracking: Estrategias con falta de fondos y cuánta falta tienen
        IStrategy[] memory strategies_needing_funds = new IStrategy[](strategies.length);
        uint256[] memory needed_amounts = new uint256[](strategies.length);

        // Variables para tracking: Estrategias con exceso y con falta de fondos
        uint256 excess_count = 0;
        uint256 needed_count = 0;

        // Itera sobre las estrategias para obtener aquellas estrategias con exceso o necesidad de fondos
        for (uint256 i = 0; i < strategies.length; i++) {
            // Obtiene la estrategia i
            IStrategy strategy = strategies[i];

            // Obtiene su balance actual y su balance target (el que debería tener) basado en el allocation
            uint256 current_balance = strategy.totalAssets();
            uint256 target_balance = (total_tvl * target_allocation[strategy]) / 10000;

            // Si tiene exceso de fondos: Añade estrategia y exceso a arrays de tracking y aumenta count
            if (current_balance > target_balance) {
                strategies_with_excess[excess_count] = strategy;
                excess_amounts[excess_count] = current_balance - target_balance;
                excess_count++;
            }
            // Si tiene necesidad de fondos: Hace lo mismo con sus arrays y count correspondiente
            else if (target_balance > current_balance) {
                strategies_needing_funds[needed_count] = strategy;
                needed_amounts[needed_count] = target_balance - current_balance;
                needed_count++;
            }
        }

        // Itera sobre el contador de estrategias con exceso para mover fondos de estr.exceso -> estr.necesidad
        for (uint256 i = 0; i < excess_count; i++) {
            // Obtiene la estrategia con exceso i, y su cantidad excedida
            IStrategy from_strategy = strategies_with_excess[i];
            uint256 available = excess_amounts[i];

            // Retira el exceso de cantidad de la estrategia i
            from_strategy.withdraw(available);

            // Itera sobre el contador de estrategias con necesidad de fondos mientras quede exceso disponible
            for (uint256 j = 0; j < needed_count && available > 0; j++) {
                // Obtiene la estrategia con necesidad j, y su cantidad necesaria
                IStrategy to_strategy = strategies_needing_funds[j];
                uint256 needed = needed_amounts[j];

                // Si necesita fondos (o sigue necesitando después de tener todo el exceso de la primera estrategia)
                if (needed > 0) {
                    // Se obtiene la cantidad mínima entre lo que excede de i y lo que necesita j
                    uint256 to_transfer = available > needed ? needed : available;

                    // Con el exceso de fondos ya en el manager se transfiere la cantidad mínima a la
                    // estrategia j y se ejecuta deposit en dicha estrategia
                    IERC20(asset).safeTransfer(address(to_strategy), to_transfer);
                    to_strategy.deposit(to_transfer);

                    // Se emite evento de rebalanceo: Estrategia desde, estrategia a la que va, cantidad
                    emit Rebalanced(address(from_strategy), address(to_strategy), to_transfer);

                    // Se resta la cantidad transferida al exceso de fondos que tenía la estrategia i
                    // y a la cantidad que necesita la estrategia j
                    available -= to_transfer;
                    needed_amounts[j] -= to_transfer;
                }
            }
        }
    }

    //* Lógica de negocio secundaria: Helper para calcular rentabilidad de rebalance y funciones para añadir y quitar estrategias

    /**
     * @notice Calcula si un rebalance es rentable
     * @dev Compara profit esperado vs gas cost estimado
     * @dev Estamos recalculando el target allocation pero no podemos
     *      llamar a _calculateTargetAllocation porque modificaríamos el state
     *
     * @dev Ejemplo de operación:
     *      Estado actual: Aave 70 WETH (5% APY), Compound 30 WETH (6% APY)
     *      Targets: Aave 45%, Compound 55% → Aave 45 WETH, Compound 55 WETH
     *
     *      Movimiento: 25 WETH de Aave → Compound
     *      Profit anual: 25 WETH * 6% = 1.5 WETH
     *      Profit semanal: 1.5 * 7/365 = 0.0287 WETH
     *
     *      Gas estimado: 2 movimientos * 300k gas = 600k gas
     *      Gas cost: 600k * 50 gwei * 2x multiplier = 0.06 WETH
     *
     *      Decisión: 0.0287 < 0.06 → NO rebalancear (no rentable)
     *
     * @return True si el rebalance es rentable
     */
    function shouldRebalance() public view returns (bool) {
        // Necesita al menos 2 estrategias para rebalancear
        if (strategies.length < 2) return false;

        // Obtiene el TVL del protocolo, y si es menor que el minimo, no rebalancea
        uint256 total_tvl = totalAssets();

        if (total_tvl < min_tvl_for_rebalance) return false;

        // temp_targets tendrá targets temporales allocations (sin modificar state)
        // totalAPY el APY actual de todas las estrategias, para calcular el global
        uint256[] memory temp_targets = new uint256[](strategies.length);
        uint256 total_apy = 0;

        // Suma APYs de todas las estrategias y comprueba que no sea cero
        for (uint256 i = 0; i < strategies.length; i++) {
            total_apy += strategies[i].apy();
        }

        if (total_apy == 0) return false;

        // Itera sobre las estrategias para calcular targets basados en APY y aplica los límites
        for (uint256 i = 0; i < strategies.length; i++) {
            // Obtiene el APY de la estrategia i
            uint256 strategy_apy = strategies[i].apy();

            // Obtiene su target allocation real (sin límites de TVL permitido)
            uint256 uncapped_target = (strategy_apy * 10000) / total_apy;

            // Si supera el máximo, su target allocation es el máximo
            if (uncapped_target > max_allocation_per_strategy) {
                temp_targets[i] = max_allocation_per_strategy;
            }
            // Si no llega al mínimo, su target allocation es 0
            else if (uncapped_target < min_allocation_threshold) {
                temp_targets[i] = 0;
            }
            // Si está entre el máximo y el mínimo, se queda con el calculado
            else {
                temp_targets[i] = uncapped_target;
            }
        }

        // total_targets contiene los targets normalizados para que sumen 100% (10000)
        uint256 total_targets = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            total_targets += temp_targets[i];
        }

        // Si la suma es mayor que cero pero no suma 100% redistribuye de nuevo
        if (total_targets > 0 && total_targets != 10000) {
            for (uint256 i = 0; i < strategies.length; i++) {
                temp_targets[i] = (temp_targets[i] * 10000) / total_targets;
            }
        }

        // Calcula profit esperado aproximado anual y numero de movimientos necesarios
        uint256 expected_annual_profit = 0;
        uint256 num_moves = 0;

        // Itera sobre las estrategias para realizar los cálculos
        for (uint256 i = 0; i < strategies.length; i++) {
            // Obtiene el balance de la estrategia y su target balance
            IStrategy strategy = strategies[i];
            uint256 current_balance = strategy.totalAssets();
            uint256 target_balance = (total_tvl * temp_targets[i]) / 10000;

            // Si son distintos calcula su delta (la diferencia con nombre hacker)
            if (current_balance != target_balance) {
                // Dependiendo de cuál sea mayor
                uint256 delta = current_balance > target_balance
                    ? current_balance - target_balance
                    : target_balance - current_balance;

                // Estima profit: fondos moviéndose ganan APY de estrategia destino
                if (target_balance > current_balance) {
                    expected_annual_profit += (delta * strategy.apy()) / 10000;
                }

                // Cuenta movimientos necesarios
                if (temp_targets[i] != target_allocation[strategies[i]]) {
                    num_moves++;
                }
            }
        }

        // Calcula el profit semanal
        uint256 weekly_profit = (expected_annual_profit * 7) / 365;

        // Estima gas cost: ~300k gas por movimiento (withdraw + deposit)
        uint256 estimated_gas = (num_moves * 300000) * tx.gasprice;

        // Rebalancea si profit semanal > gas cost * multiplicador
        return weekly_profit > (estimated_gas * gas_cost_multiplier / 100);
    }

    /**
     * @notice Añade una nueva estrategia al manager
     * @dev Solo el owner puede agregar estrategias
     * @param strategy Direccion de la estrategia a agregar
     */
    function addStrategy(address strategy) external onlyOwner {
        // Comrpueba rápidamente si la estrategia ya existe. En caso afirmativo revierte
        if (is_strategy[strategy]) revert StrategyManager__StrategyAlreadyExists();

        // Añade la estrategia al array y al mapping de rápida verificación
        strategies.push(IStrategy(strategy));
        is_strategy[strategy] = true;

        // Calcula el porcentaje del TVL para esa estrategia (su allocation)
        _calculateTargetAllocation();

        // Emite evento de estrategia añadida
        emit StrategyAdded(strategy);
    }

    /**
     * @notice Remueve una estrategia del manager
     * @dev Solo el owner puede remover estrategias
     * @dev La estrategia debe tener balance cero antes de ser removida
     * @param strategy Direccion de la estrategia a remover
     */
    function removeStrategy(address strategy) external onlyOwner {
        // Comprueba rápidamente si la estrategia no ha sido agregada
        if (!is_strategy[strategy]) revert StrategyManager__StrategyNotFound();

        // Encuentra el indice de la estrategia en el array
        uint256 index;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (address(strategies[i]) == strategy) {
                index = i;
                break;
            }
        }

        // Elimina el allocation (% del TVL) de esta estrategia antes de eliminarla
        delete target_allocation[strategies[index]];

        // Elimina la estrategia del array y el mapping de verificacion rapida
        // Utiliza la estrategia swap&pop porque ahorra gas (creo que se llamaba así)
        strategies[index] = strategies[strategies.length - 1];
        strategies.pop();
        is_strategy[strategy] = false;

        // Recalcula allocations para el resto de estrategias. Como hemos eliminado
        // esta estrategia, su allocation (% TVL) está disponible
        if (strategies.length > 0) {
            _calculateTargetAllocation();
        }

        // Emite evento de estrategia eliminada
        emit StrategyRemoved(strategy);
    }

    //* Setters de parámetros

    /**
     * @notice Actualiza el threshold minimo para rebalancing
     * @param new_threshold Nuevo threshold en basis points
     */
    function setRebalanceThreshold(uint256 new_threshold) external onlyOwner {
        rebalance_threshold = new_threshold;
    }

    /**
     * @notice Actualiza el TVL minimo para rebalancing
     * @param new_min_tvl Nuevo TVL minimo en wei
     */
    function setMinTVLForRebalance(uint256 new_min_tvl) external onlyOwner {
        min_tvl_for_rebalance = new_min_tvl;
    }

    /**
     * @notice Actualiza el multiplicador de gas cost
     * @param new_multiplier Nuevo multiplicador (base 100)
     */
    function setGasCostMultiplier(uint256 new_multiplier) external onlyOwner {
        gas_cost_multiplier = new_multiplier;
    }

    /**
     * @notice Actualiza la allocation maximo por estrategia
     * @dev Tras actualizar el máximo recalcula los allocations de nuevo
     * @param new_max Nuevo maximo en basis points
     */
    function setMaxAllocationPerStrategy(uint256 new_max) external onlyOwner {
        max_allocation_per_strategy = new_max;
        _calculateTargetAllocation();
    }

    /**
     * @notice Actualiza el threshold minimo de allocation
     * @dev Tras actualizar el máximo recalcula los allocations de nuevo
     * @param new_min Nuevo minimo en basis points
     */
    function setMinAllocationThreshold(uint256 new_min) external onlyOwner {
        min_allocation_threshold = new_min;
        _calculateTargetAllocation();
    }

    //* Funciones de consulta: TVL del protocolo, stats y count de estrategias

    /**
     * @notice Devuelve el total de assets bajo gestion en todas las estrategias
     * @dev Suma assets de todas las estrategias
     * @return total Suma de assets en todas las estrategias
     */
    function totalAssets() public view returns (uint256 total) {
        for (uint256 i = 0; i < strategies.length; i++) {
            total += strategies[i].totalAssets();
        }
    }

    /**
     * @notice Devuelve el numero de estrategias disponibles
     * @return count Cantidad de estrategias
     */
    function strategiesCount() external view returns (uint256 count) {
        return strategies.length;
    }

    /**
     * @notice Devuelve informacion de todas las estrategias
     * @return names Nombres de las estrategias
     * @return apys APYs de cada estrategia
     * @return tvls TVL de cada estrategia
     * @return targets Target allocation de cada estrategia
     */
    function getAllStrategiesInfo()
        external
        view
        returns (string[] memory names, uint256[] memory apys, uint256[] memory tvls, uint256[] memory targets)
    {
        // Tamaño del array de estrategias
        uint256 length = strategies.length;

        // Nuevos arrays con el tamaño seteado
        names = new string[](length);
        apys = new uint256[](length);
        tvls = new uint256[](length);
        targets = new uint256[](length);

        // Recorre el array de estrategias y setea valores en los nuevos arrays
        for (uint256 i = 0; i < length; i++) {
            names[i] = strategies[i].name();
            apys[i] = strategies[i].apy();
            tvls[i] = strategies[i].totalAssets();
            targets[i] = target_allocation[strategies[i]];
        }
    }

    //* Funciones internas usadas por el resto de métodos del contrato

    /**
     * @notice Calcula target allocation para cada estrategia basado en APY
     * @dev Usa weighted allocation: mayor APY = mayor porcentaje
     * @dev Aplica límites, max 50%, min 10% (por si lo oyes límites = caps)
     */
    function _calculateTargetAllocation() internal {
        // Si no existen estrategias retorna
        if (strategies.length == 0) return;

        // Suma APYs de todas las estrategias activas
        uint256 total_apy = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            total_apy += strategies[i].apy();
        }

        // Si no hay APY (todas en 0%), distribuye equitativamente. 100% / num estrategias
        if (total_apy == 0) {
            uint256 equal_share = 10000 / strategies.length;

            for (uint256 i = 0; i < strategies.length; i++) {
                target_allocation[strategies[i]] = equal_share;
            }

            emit TargetAllocationsUpdated();
            return;
        }

        // En un caso normal, las estrategias tienen APY y la suma > 0
        // distribuye el TVL en función del APY que retorna cada estrategia
        for (uint256 i = 0; i < strategies.length; i++) {
            // Itera sobre las estrategias y obtiene el apy de cada una (i)
            IStrategy strategy = strategies[i];
            uint256 strategy_apy = strategy.apy();

            // Calcula porcentaje a recibir sin límites
            uint256 uncapped_target = (strategy_apy * 10000) / total_apy;

            // Si supera el máximo, su target allocation es el máximo
            if (uncapped_target > max_allocation_per_strategy) {
                target_allocation[strategy] = max_allocation_per_strategy;
            }
            // Si no llega al mínimo, su target allocation es 0
            else if (uncapped_target < min_allocation_threshold) {
                target_allocation[strategy] = 0;
            }
            // Si está entre el máximo y el mínimo, se queda con el calculado
            else {
                target_allocation[strategy] = uncapped_target;
            }
        }

        // Comprueba que los target allocations sumen exactamente 10000 (100%)
        uint256 total_allocated = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            total_allocated += target_allocation[strategies[i]];
        }

        // Si no suman 10000 (100%), ese porcentaje perdido se distribuye proporcionalmente entre las estrategias
        if (total_allocated > 0 && total_allocated != 10000) {
            for (uint256 i = 0; i < strategies.length; i++) {
                if (target_allocation[strategies[i]] > 0) {
                    target_allocation[strategies[i]] = (target_allocation[strategies[i]] * 10000) / total_allocated;
                }
            }
        }

        // Emite evento de targets allocations actualizados
        emit TargetAllocationsUpdated();
    }
}
