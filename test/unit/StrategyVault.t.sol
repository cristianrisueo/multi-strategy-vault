// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {StrategyVault} from "../../src/core/StrategyVault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../../src/strategies/CompoundStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title StrategyVaultUnitTest
 * @notice Suite completa de tests unitarios para StrategyVault
 * @dev Tests con fork de Sepolia usando estrategias reales de Aave y Compound
 */
contract StrategyVaultUnitTest is Test {
    //* Variables de estado

    /// @notice Instancia del StrategyVault a testear
    StrategyVault public vault;

    /// @notice Instancia del StrategyManager
    StrategyManager public manager;

    /// @notice Estrategias reales
    AaveStrategy public aave_strategy;
    CompoundStrategy public compound_strategy;

    /// @notice Direcciones de los contratos en Sepolia
    address constant WETH = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;
    address constant AAVE_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant COMPOUND_COMET = 0xAec1F48e02Cfb822Be958B68C7957156EB3F0b6e;

    /// @notice Usuarios de prueba
    address public owner;
    address public fee_receiver;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    /// @notice Parámetros iniciales del vault
    uint256 constant IDLE_THRESHOLD = 10 ether;
    uint256 constant MAX_TVL = 1000 ether;
    uint256 constant MIN_DEPOSIT = 0.01 ether;
    uint256 constant WITHDRAWAL_FEE = 200; // 2%

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing con fork de Sepolia
     * @dev Despliega vault, manager y estrategias reales
     */
    function setUp() public {
        // Fork Sepolia para tests con protocolos reales
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        // Configurar direcciones
        owner = address(this);
        fee_receiver = makeAddr("feeReceiver");

        // Deploy Manager (solo con asset ahora)
        manager = new StrategyManager(WETH);

        // Deploy Vault con manager real
        vault = new StrategyVault(WETH, address(manager), fee_receiver, IDLE_THRESHOLD);

        // Inicializar vault en manager (one-time call)
        manager.initializeVault(address(vault));

        // Deploy estrategias reales
        aave_strategy = new AaveStrategy(address(manager), WETH, AAVE_POOL);
        compound_strategy = new CompoundStrategy(address(manager), WETH, COMPOUND_COMET);

        // Agregar estrategias al manager
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(compound_strategy));
    }

    //* Test unitarios de lógica principal: Depósitos

    /**
     * @notice Test basico de deposito
     * @dev Comprueba que un usuario pueda depositar y recibir shares correctamente
     */
    function test_DepositBasic() public {
        // Cantidad a depositar: 1 WETH
        uint256 deposit_amount = 1 ether;

        // Entrega la cantidad a Alice y usa su cuenta para depositar
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        // Aprueba el vault para gastar su WETH y deposita
        IERC20(WETH).approve(address(vault), deposit_amount);
        uint256 shares_received = vault.deposit(deposit_amount, alice);

        vm.stopPrank();

        // Comprueba que las shares de Alice en el vault y las recibidas coinciden
        assertEq(vault.balanceOf(alice), shares_received, "Shares incorrectas");

        // Comprueba que el total de assets del vault incluye el deposito
        // (estará en idle buffer porque no alcanza threshold)
        assertEq(vault.totalAssets(), deposit_amount, "Total assets incorrecto");
        assertEq(vault.idle_weth(), deposit_amount, "Idle buffer incorrecto");
    }

    /**
     * @notice Test de deposito con cantidad cero
     * @dev Debe revertir al intentar depositar 0
     */
    function test_DepositZeroReverts() public {
        vm.prank(alice);

        vm.expectRevert(StrategyVault.StrategyVault__ZeroAmount.selector);
        vault.deposit(0, alice);
    }

    /**
     * @notice Test de deposito por debajo del minimo
     * @dev Debe revertir si el deposito es menor que min_deposit
     */
    function test_DepositBelowMinReverts() public {
        // Cantidad menor al minimo (0.01 ETH)
        uint256 below_min = 0.005 ether;

        // Alice intenta depositar
        deal(WETH, alice, below_min);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), below_min);

        // Espera que revierta por estar por debajo del minimo
        vm.expectRevert(StrategyVault.StrategyVault__BelowMinDeposit.selector);
        vault.deposit(below_min, alice);

        vm.stopPrank();
    }

    /**
     * @notice Test de deposito cuando el vault esta pausado
     * @dev Debe revertir si se intenta depositar mientras esta pausado
     */
    function test_DepositWhenPausedReverts() public {
        // Cantidad a depositar: 1 WETH
        uint256 deposit_amount = 1 ether;

        // Se pausa el vault
        vault.pause();

        // Entrega la cantidad a Alice y usa su cuenta para depositar
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        // Aprueba el vault para gastar su WETH
        IERC20(WETH).approve(address(vault), deposit_amount);

        // Espera que se revierta por estar pausado el vault, y deposita
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(deposit_amount, alice);

        vm.stopPrank();
    }

    /**
     * @notice Test de deposito excediendo max TVL
     * @dev Debe revertir si el deposito supera el limite de TVL
     */
    function test_DepositExceedingMaxTVLReverts() public {
        // Obtiene el max TVL actual del vault y aumenta la cantidad a depositar
        uint256 max_tvl = vault.max_tvl();
        uint256 exceeding_amount = max_tvl + 1 ether;

        // Dar la cantidad de exceso a Alice
        deal(WETH, alice, exceeding_amount);
        vm.startPrank(alice);

        // Aprueba el vault para gastar su WETH
        IERC20(WETH).approve(address(vault), exceeding_amount);

        // Espera que se revierta por exceder el max TVL, y deposita
        vm.expectRevert(StrategyVault.StrategyVault__MaxTVLExceeded.selector);
        vault.deposit(exceeding_amount, alice);

        vm.stopPrank();
    }

    /**
     * @notice Test de deposito que NO trigger allocate (bajo threshold)
     * @dev El deposito se acumula en idle buffer sin enviarse al manager
     */
    function test_DepositDoesNotTriggerIdleAllocation() public {
        // Cantidad menor al threshold (10 ETH)
        uint256 deposit_amount = 5 ether;

        // Alice deposita
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        vm.stopPrank();

        // Comprueba que el WETH esta en idle, no en manager
        assertEq(vault.idle_weth(), deposit_amount, "No se acumulo en idle");
        assertEq(manager.totalAssets(), 0, "No deberia haber assets en manager");
    }

    /**
     * @notice Test de deposito que SÍ trigger allocate (alcanza threshold)
     * @dev El idle buffer se vacia automaticamente hacia el manager
     */
    function test_DepositTriggersIdleAllocation() public {
        // Cantidad que alcanza el threshold (10 ETH)
        uint256 deposit_amount = 10 ether;

        // Alice deposita
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        vm.stopPrank();

        // Comprueba que idle buffer se vacio y los fondos estan en manager/estrategias
        assertEq(vault.idle_weth(), 0, "Idle deberia estar vacio");
        assertGt(manager.totalAssets(), 0, "Manager deberia tener assets");
    }

    /**
     * @notice Test de multiples depositos secuenciales
     * @dev Comprueba que varios usuarios puedan depositar sin problemas
     */
    function test_MultipleDepositsSequential() public {
        // Cantidades a depositar por cada usuario
        uint256 amount_alice = 2 ether;
        uint256 amount_bob = 3 ether;
        uint256 amount_charlie = 1.5 ether;

        // Entrega la cantidad a Alice y deposita
        deal(WETH, alice, amount_alice);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), amount_alice);
        vault.deposit(amount_alice, alice);
        vm.stopPrank();

        // Entrega la cantidad a Bob y deposita
        deal(WETH, bob, amount_bob);
        vm.startPrank(bob);
        IERC20(WETH).approve(address(vault), amount_bob);
        vault.deposit(amount_bob, bob);
        vm.stopPrank();

        // Entrega la cantidad a Charlie y deposita
        deal(WETH, charlie, amount_charlie);
        vm.startPrank(charlie);
        IERC20(WETH).approve(address(vault), amount_charlie);
        vault.deposit(amount_charlie, charlie);
        vm.stopPrank();

        // Comprueba que el total de assets del vault es correcto
        uint256 expected_total = amount_alice + amount_bob + amount_charlie;
        assertEq(vault.totalAssets(), expected_total, "Total assets incorrecto");
    }

    //* Test unitarios de lógica principal: Mint

    /**
     * @notice Test basico de mint
     * @dev Comprueba que un usuario pueda mintear shares específicas
     */
    function test_MintBasic() public {
        // Shares a mintear
        uint256 shares_to_mint = 5 ether;

        // Alice mintea shares
        deal(WETH, alice, 10 ether);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), 10 ether);
        uint256 assets_deposited = vault.mint(shares_to_mint, alice);

        vm.stopPrank();

        // Comprueba que Alice tiene las shares correctas
        assertEq(vault.balanceOf(alice), shares_to_mint, "Shares incorrectas");
        assertGt(assets_deposited, 0, "Deberia haber depositado assets");
    }

    /**
     * @notice Test de mint con cantidad cero
     * @dev Debe revertir al intentar mintear 0 shares
     */
    function test_MintZeroReverts() public {
        vm.prank(alice);

        vm.expectRevert(StrategyVault.StrategyVault__ZeroAmount.selector);
        vault.mint(0, alice);
    }

    /**
     * @notice Test de mint cuando el vault esta pausado
     * @dev Debe revertir si se intenta mintear mientras esta pausado
     */
    function test_MintWhenPausedReverts() public {
        // Shares a mintear
        uint256 shares_to_mint = 1 ether;

        // Se pausa el vault
        vault.pause();

        // Alice intenta mintear
        deal(WETH, alice, 10 ether);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), 10 ether);

        // Espera que revierta por estar pausado
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.mint(shares_to_mint, alice);

        vm.stopPrank();
    }

    //* Test unitarios de lógica principal: Retiros

    /**
     * @notice Test basico de retiro
     * @dev Comprueba que un usuario pueda retirar sus fondos correctamente
     */
    function test_WithdrawBasic() public {
        // Cantidad a depositar y luego retirar: 5 WETH
        uint256 deposit_amount = 5 ether;

        // Setup: Alice deposita primero
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        // Alice retira assets (descontando fee del 2%)
        uint256 expected_net = (deposit_amount * (10000 - WITHDRAWAL_FEE)) / 10000;
        vault.withdraw(expected_net, alice, alice);

        vm.stopPrank();

        // Comprobaciones: Alice recibio WETH neto (menos fee)
        assertEq(IERC20(WETH).balanceOf(alice), expected_net, "Alice no recibio WETH neto");

        // Comprueba que shares fueron quemadas (no exactamente 0 por fee)
        assertLt(vault.balanceOf(alice), deposit_amount / 100, "Shares no quemadas correctamente");
    }

    /**
     * @notice Test de retiro con cantidad cero
     * @dev Debe revertir al intentar retirar 0
     */
    function test_WithdrawZeroReverts() public {
        vm.prank(alice);

        vm.expectRevert(StrategyVault.StrategyVault__ZeroAmount.selector);
        vault.withdraw(0, alice, alice);
    }

    /**
     * @notice Test de retiro parcial
     * @dev Usuario retira solo una parte de su deposito
     */
    function test_WithdrawPartial() public {
        // Cantidades a depositar y retirar
        uint256 deposit_amount = 10 ether;
        uint256 withdraw_amount = 3 ether; // Retira 3 ETH netos

        // Setup: Alice deposita
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        // Alice retira cantidad parcial
        vault.withdraw(withdraw_amount, alice, alice);

        vm.stopPrank();

        // Comprobaciones: Alice tiene shares restantes
        assertGt(vault.balanceOf(alice), 0, "Alice no tiene shares restantes");

        // Comprueba que Alice recibio la cantidad neta
        assertEq(IERC20(WETH).balanceOf(alice), withdraw_amount, "Balance WETH incorrecto");
    }

    /**
     * @notice Test de retiro cuando el vault esta pausado
     * @dev Debe revertir si se intenta retirar mientras esta pausado
     */
    function test_WithdrawWhenPausedReverts() public {
        // Cantidad a depositar: 5 WETH
        uint256 deposit_amount = 5 ether;

        // Setup: Alice deposita primero
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        vm.stopPrank();

        // Owner pausa el vault
        vault.pause();

        // Alice no deberia poder retirar
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.withdraw(deposit_amount, alice, alice);
    }

    /**
     * @notice Test de calculo de withdrawal fee
     * @dev Verifica que el fee sea exactamente 2% de los assets brutos
     */
    function test_WithdrawFeeCalculation() public {
        // Deposito grande para testear fee
        uint256 deposit_amount = 100 ether;

        // Setup: Alice deposita
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        // Balance del fee receiver antes
        uint256 fee_receiver_before = IERC20(WETH).balanceOf(fee_receiver);

        // Alice retira cantidad neta de 50 ETH
        uint256 net_withdraw = 50 ether;
        vault.withdraw(net_withdraw, alice, alice);

        vm.stopPrank();

        // Calcula fee esperado: fee = (net × fee_bp) / (10000 - fee_bp)
        // Para net = 50 ETH y fee = 200bp: fee = 50 × 200 / 9800 ≈ 1.02 ETH
        uint256 expected_fee = (net_withdraw * WITHDRAWAL_FEE) / (10000 - WITHDRAWAL_FEE);

        // Balance del fee receiver despues
        uint256 fee_receiver_after = IERC20(WETH).balanceOf(fee_receiver);
        uint256 actual_fee = fee_receiver_after - fee_receiver_before;

        // Comprueba que el fee es correcto
        assertEq(actual_fee, expected_fee, "Fee calculation incorrecto");
    }

    /**
     * @notice Test de retiro desde idle buffer primero
     * @dev Verifica que el retiro use idle buffer antes de tocar manager
     */
    function test_WithdrawFromIdleFirst() public {
        // Deposito que no alcanza threshold (se queda en idle)
        uint256 deposit_amount = 5 ether;

        // Setup: Alice deposita
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        // Retira cantidad menor al idle
        uint256 withdraw_amount = 2 ether;
        vault.withdraw(withdraw_amount, alice, alice);

        vm.stopPrank();

        // Comprueba que manager no fue tocado
        assertEq(manager.totalAssets(), 0, "Manager no deberia haber sido tocado");

        // Comprueba que idle buffer disminuyo
        assertLt(vault.idle_weth(), deposit_amount, "Idle no disminuyo");
    }

    /**
     * @notice Test de retiro desde manager cuando idle es insuficiente
     * @dev Verifica que se retira de manager si idle no alcanza
     */
    function test_WithdrawFromManagerWhenIdleInsufficient() public {
        // Deposito grande que alcanza threshold (va a manager)
        uint256 deposit_amount = 20 ether;

        // Setup: Alice deposita
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        // Retira cantidad grande (más de lo que hay en idle)
        uint256 withdraw_amount = 15 ether;
        vault.withdraw(withdraw_amount, alice, alice);

        vm.stopPrank();

        // Comprueba que manager fue usado para el retiro
        assertLt(manager.totalAssets(), deposit_amount, "Manager deberia haber disminuido");
    }

    //* Test unitarios de lógica principal: Redeem

    /**
     * @notice Test basico de redeem
     * @dev Comprueba que un usuario pueda quemar shares y recibir assets
     */
    function test_RedeemBasic() public {
        // Cantidad a depositar: 10 WETH
        uint256 deposit_amount = 10 ether;

        // Setup: Alice deposita
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), deposit_amount);
        uint256 shares = vault.deposit(deposit_amount, alice);

        // Alice redime todas sus shares
        uint256 assets_received = vault.redeem(shares, alice, alice);

        vm.stopPrank();

        // Comprobaciones: Alice quemo shares y recibio assets (menos fee)
        assertEq(vault.balanceOf(alice), 0, "Alice aun tiene shares");
        assertGt(assets_received, 0, "Alice no recibio assets");

        // Verifica que recibio menos del deposito original (por fee)
        assertLt(assets_received, deposit_amount, "Assets deberian ser menores por fee");
    }

    /**
     * @notice Test de redeem con cantidad cero
     * @dev Debe revertir al intentar redimir 0 shares
     */
    function test_RedeemZeroReverts() public {
        vm.prank(alice);

        vm.expectRevert(StrategyVault.StrategyVault__ZeroAmount.selector);
        vault.redeem(0, alice, alice);
    }

    /**
     * @notice Test de redeem cuando el vault esta pausado
     * @dev Debe revertir si se intenta redimir mientras esta pausado
     */
    function test_RedeemWhenPausedReverts() public {
        // Cantidad a depositar: 5 WETH
        uint256 deposit_amount = 5 ether;

        // Setup: Alice deposita
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), deposit_amount);
        uint256 shares = vault.deposit(deposit_amount, alice);

        vm.stopPrank();

        // Owner pausa el vault
        vault.pause();

        // Alice no deberia poder redimir
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.redeem(shares, alice, alice);
    }

    //* Test unitarios de lógica adicional: Idle buffer management

    /**
     * @notice Test de allocate idle manual
     * @dev Owner puede forzar allocate del idle buffer
     */
    function test_ManualAllocateIdleOnlyOwner() public {
        // Deposito que NO alcanza threshold
        uint256 deposit_amount = 5 ether;

        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);
        vm.stopPrank();

        // Verifica que idle tiene fondos
        assertEq(vault.idle_weth(), deposit_amount, "Idle deberia tener fondos");

        // Alice intenta allocate manualmente (deberia revertir)
        vm.prank(alice);
        vm.expectRevert();
        vault.allocateIdle();

        // Owner puede allocate manualmente
        vault.allocateIdle();

        // Verifica que idle se vacio
        assertEq(vault.idle_weth(), 0, "Idle deberia estar vacio");
        assertGt(manager.totalAssets(), 0, "Manager deberia tener assets");
    }

    /**
     * @notice Test de allocate idle cuando esta por debajo del threshold
     * @dev Debe revertir si idle < threshold al intentar allocate manual
     */
    function test_ManualAllocateIdleWhenBelowThresholdReverts() public {
        // Deposito muy pequeño
        uint256 small_deposit = 1 ether;

        deal(WETH, alice, small_deposit);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), small_deposit);
        vault.deposit(small_deposit, alice);
        vm.stopPrank();

        // Owner intenta allocate pero esta por debajo del threshold
        vm.expectRevert(StrategyVault.StrategyVault__IdleBelowThreshold.selector);
        vault.allocateIdle();
    }

    //* Test unitarios de lógica adicional: Admin functions

    /**
     * @notice Test de setIdleThreshold solo owner
     * @dev Solo el owner puede cambiar el idle threshold
     */
    function test_SetIdleThresholdOnlyOwner() public {
        uint256 new_threshold = 20 ether;

        // Alice intenta cambiar (deberia revertir)
        vm.prank(alice);
        vm.expectRevert();
        vault.setIdleThreshold(new_threshold);

        // Owner puede cambiar
        vault.setIdleThreshold(new_threshold);
        assertEq(vault.idle_threshold(), new_threshold, "Threshold no actualizado");
    }

    /**
     * @notice Test de setMaxTVL solo owner
     * @dev Solo el owner puede cambiar el max TVL
     */
    function test_SetMaxTVLOnlyOwner() public {
        uint256 new_max_tvl = 2000 ether;

        // Alice intenta cambiar (deberia revertir)
        vm.prank(alice);
        vm.expectRevert();
        vault.setMaxTVL(new_max_tvl);

        // Owner puede cambiar
        vault.setMaxTVL(new_max_tvl);
        assertEq(vault.max_tvl(), new_max_tvl, "Max TVL no actualizado");
    }

    /**
     * @notice Test de setMinDeposit solo owner
     * @dev Solo el owner puede cambiar el deposito minimo
     */
    function test_SetMinDepositOnlyOwner() public {
        uint256 new_min_deposit = 0.1 ether;

        // Alice intenta cambiar (deberia revertir)
        vm.prank(alice);
        vm.expectRevert();
        vault.setMinDeposit(new_min_deposit);

        // Owner puede cambiar
        vault.setMinDeposit(new_min_deposit);
        assertEq(vault.min_deposit(), new_min_deposit, "Min deposit no actualizado");
    }

    /**
     * @notice Test de setWithdrawalFee solo owner
     * @dev Solo el owner puede cambiar el withdrawal fee
     */
    function test_SetWithdrawalFeeOnlyOwner() public {
        uint256 new_fee = 300; // 3%

        // Alice intenta cambiar (deberia revertir)
        vm.prank(alice);
        vm.expectRevert();
        vault.setWithdrawalFee(new_fee);

        // Owner puede cambiar
        vault.setWithdrawalFee(new_fee);
        assertEq(vault.withdrawal_fee(), new_fee, "Withdrawal fee no actualizado");
    }

    /**
     * @notice Test de setWithdrawalFeeReceiver solo owner
     * @dev Solo el owner puede cambiar el fee receiver
     */
    function test_SetWithdrawalFeeReceiverOnlyOwner() public {
        address new_receiver = makeAddr("newReceiver");

        // Alice intenta cambiar (deberia revertir)
        vm.prank(alice);
        vm.expectRevert();
        vault.setWithdrawalFeeReceiver(new_receiver);

        // Owner puede cambiar
        vault.setWithdrawalFeeReceiver(new_receiver);
        assertEq(vault.fee_receiver(), new_receiver, "Fee receiver no actualizado");
    }

    /**
     * @notice Test de pause solo owner
     * @dev Solo el owner puede pausar
     */
    function test_PauseOnlyOwner() public {
        // Alice intenta pausar (deberia revertir)
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();

        // Owner puede pausar
        vault.pause();
        assertTrue(vault.paused(), "Vault no esta pausado");
    }

    /**
     * @notice Test de unpause solo owner
     * @dev Solo el owner puede despausar
     */
    function test_UnpauseOnlyOwner() public {
        // Owner pausa primero
        vault.pause();

        // Alice intenta despausar (deberia revertir)
        vm.prank(alice);
        vm.expectRevert();
        vault.unpause();

        // Owner puede despausar
        vault.unpause();
        assertFalse(vault.paused(), "Vault aun esta pausado");
    }

    //* Test unitarios de funciones ERC4626: Preview y Max functions

    /**
     * @notice Test de previewDeposit
     * @dev Comprueba que preview devuelva shares correctas antes de depositar
     */
    function test_PreviewDeposit() public view {
        uint256 assets = 10 ether;

        uint256 expected_shares = vault.previewDeposit(assets);

        // Sin depositos previos, ratio 1:1
        assertEq(expected_shares, assets, "Preview deposit incorrecto");
    }

    /**
     * @notice Test de previewMint
     * @dev Comprueba que preview devuelva assets necesarios para mintear shares
     */
    function test_PreviewMint() public view {
        uint256 shares = 10 ether;

        uint256 expected_assets = vault.previewMint(shares);

        // Sin depositos previos, ratio 1:1
        assertEq(expected_assets, shares, "Preview mint incorrecto");
    }

    /**
     * @notice Test de previewWithdraw con fee
     * @dev Verifica que preview calcule shares necesarias incluyendo fee
     */
    function test_PreviewWithdraw() public {
        // Deposito inicial
        uint256 deposit_amount = 100 ether;
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);
        vm.stopPrank();

        // Preview para retirar 50 ETH netos
        uint256 assets_to_withdraw = 50 ether;
        uint256 shares_needed = vault.previewWithdraw(assets_to_withdraw);

        // Shares needed deberian incluir el fee
        assertGt(shares_needed, assets_to_withdraw, "Preview deberia incluir fee");
    }

    /**
     * @notice Test de previewRedeem con fee
     * @dev Verifica que preview calcule assets netos descontando fee
     */
    function test_PreviewRedeem() public {
        // Deposito inicial
        uint256 deposit_amount = 100 ether;
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), deposit_amount);
        uint256 shares = vault.deposit(deposit_amount, alice);
        vm.stopPrank();

        // Preview para redimir todas las shares
        uint256 assets_to_receive = vault.previewRedeem(shares);

        // Assets recibidos deberian ser menores por el fee
        assertLt(assets_to_receive, deposit_amount, "Preview deberia descontar fee");
    }

    /**
     * @notice Test de maxDeposit
     * @dev Verifica que maxDeposit respete el max TVL
     */
    function test_MaxDeposit() public view {
        uint256 max_deposit = vault.maxDeposit(alice);

        // Debe ser igual a max_tvl cuando vault esta vacio
        assertEq(max_deposit, MAX_TVL, "Max deposit incorrecto");
    }

    /**
     * @notice Test de maxMint
     * @dev Verifica que maxMint respete el max TVL
     */
    function test_MaxMint() public view {
        uint256 max_mint = vault.maxMint(alice);

        // Debe ser igual a max_tvl cuando vault esta vacio (ratio 1:1)
        assertEq(max_mint, MAX_TVL, "Max mint incorrecto");
    }

    //* Test unitarios de funciones de consulta: Conversiones

    /**
     * @notice Test de conversion shares a assets
     * @dev Comprueba que la conversion de shares a assets sea correcta
     */
    function test_ConvertToAssets() public {
        // Cantidad a depositar: 10 WETH
        uint256 deposit_amount = 10 ether;

        // Alice deposita
        deal(WETH, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), deposit_amount);
        uint256 shares = vault.deposit(deposit_amount, alice);

        vm.stopPrank();

        // Convierte las shares recibidas a assets
        uint256 assets = vault.convertToAssets(shares);

        // Comprueba que los assets recibidos sean correctos
        assertEq(assets, deposit_amount, "Conversion incorrecta");
    }

    /**
     * @notice Test de conversion assets a shares
     * @dev Comprueba que la conversion de assets a shares sea correcta
     */
    function test_ConvertToShares() public view {
        // Cantidad de assets a convertir: 5 WETH
        uint256 assets = 5 ether;

        // Sin depositos previos, ratio 1:1
        uint256 shares = vault.convertToShares(assets);

        // Comprueba que shares y assets coinciden
        assertEq(shares, assets, "Conversion inicial incorrecta");
    }

    //* Test unitarios de funciones de consulta: TotalAssets

    /**
     * @notice Test de totalAssets con idle y manager
     * @dev Verifica que totalAssets sume idle + manager correctamente
     */
    function test_TotalAssets() public {
        // Deposito que se queda en idle
        uint256 idle_deposit = 5 ether;
        deal(WETH, alice, idle_deposit);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), idle_deposit);
        vault.deposit(idle_deposit, alice);
        vm.stopPrank();

        // Deposito que va a manager
        uint256 manager_deposit = 10 ether;
        deal(WETH, bob, manager_deposit);
        vm.startPrank(bob);
        IERC20(WETH).approve(address(vault), manager_deposit);
        vault.deposit(manager_deposit, bob);
        vm.stopPrank();

        // Total deberia ser suma de idle + manager
        uint256 total_expected = idle_deposit + manager_deposit;
        assertEq(vault.totalAssets(), total_expected, "Total assets incorrecto");
    }
}
