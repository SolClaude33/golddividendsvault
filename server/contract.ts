// EVM Contract Reader Service
// Reads data from the Gold Dividend Vault contract on BNB Smart Chain (BSC)

import { createPublicClient, http, formatEther, type PublicClient } from "viem";
import { bsc } from "viem/chains";

const TOKEN_ADDRESS = "0xdCCf9Ac19362C6d60e69A196fC6351C4A0887777";
const TAX_PROCESSOR_ADDRESS = "0xF7e36953aEDF448cbB9cE5fA123742e3543A82D8";
const VAULT_CONTRACT_ADDRESS = process.env.VAULT_CONTRACT_ADDRESS || "";

// ABI updated for new token contract (dashboard reads quote buckets)
const TAX_PROCESSOR_ABI = [
  {
    "inputs": [],
    "name": "quoteFounder",
    "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "quoteHolder",
    "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  }
] as const;

interface ContractData {
  fundsBalance: string;
  feesConvertedToGold: string;
  liquidityBalance: string;
  tokenAddress: string;
  taxProcessorAddress: string;
}

export interface VaultStats {
  totalBNBReceived: string;
  totalBNBConvertedToGold: string;
  goldFundBalance: string;
  treasuryBNBBalance: string;
  currentGoldBalance: string;
  totalGoldDistributed: string;
  distributionActive: boolean;
  distributionsPaused: boolean;
}

const VAULT_ABI = [
  {
    inputs: [],
    name: "getVaultStats",
    outputs: [
      { internalType: "uint256", name: "_totalBNBReceived",        type: "uint256" },
      { internalType: "uint256", name: "_totalBNBConvertedToGold", type: "uint256" },
      { internalType: "uint256", name: "_goldFundBalance",         type: "uint256" },
      { internalType: "uint256", name: "_treasuryBNBBalance",      type: "uint256" },
      { internalType: "uint256", name: "_currentGoldBalance",      type: "uint256" },
      { internalType: "uint256", name: "_totalGoldDistributed",    type: "uint256" },
      { internalType: "bool",    name: "_distributionActive",      type: "bool"    },
      { internalType: "bool",    name: "_distributionsPaused",     type: "bool"    },
    ],
    stateMutability: "view",
    type: "function",
  },
] as const;

const ZERO_VAULT_STATS: VaultStats = {
  totalBNBReceived:        "0",
  totalBNBConvertedToGold: "0",
  goldFundBalance:         "0",
  treasuryBNBBalance:      "0",
  currentGoldBalance:      "0",
  totalGoldDistributed:    "0",
  distributionActive:      false,
  distributionsPaused:     false,
};

export async function getVaultStats(): Promise<VaultStats> {
  if (!VAULT_CONTRACT_ADDRESS) {
    console.log("[Vault] VAULT_CONTRACT_ADDRESS not set, returning zeros.");
    return ZERO_VAULT_STATS;
  }
  try {
    const publicClient: PublicClient = createPublicClient({
      chain: bsc,
      transport: http(process.env.EVM_RPC_URL || "https://bsc-dataseed1.binance.org"),
    });

    console.log("[Vault] Reading getVaultStats from:", VAULT_CONTRACT_ADDRESS);

    const result = await publicClient.readContract({
      address: VAULT_CONTRACT_ADDRESS as `0x${string}`,
      abi: VAULT_ABI,
      functionName: "getVaultStats",
    });

    const stats: VaultStats = {
      totalBNBReceived:        formatEther(result[0]),
      totalBNBConvertedToGold: formatEther(result[1]),
      goldFundBalance:         formatEther(result[2]),
      treasuryBNBBalance:      formatEther(result[3]),
      currentGoldBalance:      formatEther(result[4]),
      totalGoldDistributed:    formatEther(result[5]),
      distributionActive:      result[6],
      distributionsPaused:     result[7],
    };

    console.log("[Vault] Stats:", stats);
    return stats;
  } catch (error: any) {
    console.log("[Vault] Error reading vault stats:", error?.message || String(error));
    return ZERO_VAULT_STATS;
  }
}

export async function getContractData(): Promise<ContractData> {
  try {
    console.log("[Contract] Initializing viem client for BSC...");
    
    // Create public client for BSC Mainnet (same as umamusume)
    const publicClient: PublicClient = createPublicClient({
      chain: bsc,
      transport: http(process.env.EVM_RPC_URL || "https://bsc-dataseed1.binance.org"),
    });

    console.log("[Contract] Reading from Token contract:", TAX_PROCESSOR_ADDRESS);

    // Read quote buckets from token contract.
    // Dashboard mapping:
    // - quoteFounder() holds the combined quote bucket for founder/fees split
    //   We split it into:
    //   - fundsBalance (Treasury 10%)
    //   - feesConvertedToGold (75%)
    // - liquidityBalance (15% card) -> quoteHolder()
    const [quoteFounder, quoteHolder] = await Promise.all([
      publicClient.readContract({
        address: TAX_PROCESSOR_ADDRESS as `0x${string}`,
        abi: TAX_PROCESSOR_ABI,
        functionName: "quoteFounder",
      }).catch((error: any) => {
        console.log("[Contract] Error reading quoteFounder:", error?.message || String(error));
        return 0n;
      }),
      publicClient.readContract({
        address: TAX_PROCESSOR_ADDRESS as `0x${string}`,
        abi: TAX_PROCESSOR_ABI,
        functionName: "quoteHolder",
      }).catch((error: any) => {
        console.log("[Contract] Error reading quoteHolder:", error?.message || String(error));
        return 0n;
      })
    ]);

    // Split quoteFounder into 75% (fees converted to gold) + 10% (treasury)
    // NOTE: quoteFounder represents the combined (75 + 10) bucket, so we split by ratio.
    // Treasury share = 10 / (75 + 10) = 10/85
    const treasuryWei = (quoteFounder * 10n) / 85n;
    const goldWei = quoteFounder - treasuryWei;

    // Convert from wei to BNB using formatEther
    const fundsBalance = formatEther(treasuryWei);
    const feesConvertedToGold = formatEther(goldWei);
    const liquidityBalance = formatEther(quoteHolder);

    console.log("[Contract] Successfully read contract data:", {
      fundsBalance,
      feesConvertedToGold,
      liquidityBalance,
      quoteFounderRaw: quoteFounder.toString(),
      quoteHolderRaw: quoteHolder.toString(),
    });

    return {
      fundsBalance,
      feesConvertedToGold,
      liquidityBalance,
      tokenAddress: TOKEN_ADDRESS,
      taxProcessorAddress: TAX_PROCESSOR_ADDRESS,
    };
  } catch (error: any) {
    console.log("[Contract] Error reading contract data:", error?.message || String(error));
    console.log("[Contract] Error stack:", error?.stack);
    
    // Return zeros if contract read fails
    return {
      fundsBalance: "0",
      feesConvertedToGold: "0",
      liquidityBalance: "0",
      tokenAddress: TOKEN_ADDRESS,
      taxProcessorAddress: TAX_PROCESSOR_ADDRESS,
    };
  }
}

// Keep formatTokenAmount for backwards compatibility (though we use formatEther now)
export function formatTokenAmount(weiAmount: string, decimals: number = 18): string {
  try {
    const cleanAmount = weiAmount.startsWith("0x") ? weiAmount.slice(2) : weiAmount;
    if (!cleanAmount || cleanAmount === "0") return "0";
    
    const amount = BigInt("0x" + cleanAmount);
    const divisor = BigInt(10 ** decimals);
    const whole = amount / divisor;
    const remainder = amount % divisor;
    
    const remainderStr = remainder.toString().padStart(decimals, "0");
    const trimmedRemainder = remainderStr.replace(/0+$/, "");
    
    return trimmedRemainder ? `${whole}.${trimmedRemainder}` : whole.toString();
  } catch (error) {
    console.error("[Contract] Error formatting amount:", error);
    return "0";
  }
}
