import Foundation
import StoreKit

/// StoreKit 2 subscription state for Screen Divider Pro.
///
/// Two auto-renewable products in one subscription group; either one
/// unlocks the app. Entitlement checks work offline via the locally
/// cached transaction data, so a lapsed network connection never locks
/// out a paying user.
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    static let monthlyProductID = "com.harveycreative.screendivider.monthly"
    static let yearlyProductID = "com.harveycreative.screendivider.yearly"
    static let allProductIDs = [monthlyProductID, yearlyProductID]

    private(set) var isSubscribed = false
    /// False until the first entitlement check completes after launch.
    private(set) var statusKnown = false
    /// Ordered monthly-first; empty until the App Store responds.
    private(set) var products: [Product] = []

    /// Called on the main thread after every entitlement refresh.
    var onStatusRefreshed: ((_ isSubscribed: Bool) -> Void)?
    /// Called on the main thread when products finish loading.
    var onProductsLoaded: (([Product]) -> Void)?

    private var updatesTask: Task<Void, Never>?

    func start() {
        // Listen for renewals, cancellations, refunds, and purchases
        // completed outside the app (e.g. from the App Store).
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
        Task { [weak self] in
            await self?.refreshEntitlement()
            await self?.loadProducts()
        }
    }

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: Self.allProductIDs)
            let ordered = Self.allProductIDs.compactMap { id in loaded.first(where: { $0.id == id }) }
            DispatchQueue.main.async {
                self.products = ordered
                self.onProductsLoaded?(ordered)
            }
        } catch {
            NSLog("ScreenDivider: Failed to load products: \(error)")
        }
    }

    func refreshEntitlement() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if Self.allProductIDs.contains(transaction.productID), transaction.revocationDate == nil {
                entitled = true
            }
        }
        #if DEBUG
        // Dev-build escape hatch so `swift build` runs work without a receipt.
        if ProcessInfo.processInfo.environment["SD_DEV_UNLOCK"] == "1" { entitled = true }
        #endif
        #if SD_LOCAL_UNLOCK
        // Local self-hosted build. Enabled by placing a `.local-unlock` marker
        // file next to install.sh, which passes -D SD_LOCAL_UNLOCK to swiftc.
        // App Store / xcodegen archive builds never define this flag, so the
        // paywall stays intact for distribution.
        entitled = true
        #endif
        let newValue = entitled
        DispatchQueue.main.async {
            self.isSubscribed = newValue
            self.statusKnown = true
            self.onStatusRefreshed?(newValue)
        }
    }

    /// Runs a purchase. Returns true if the transaction succeeded
    /// (entitlement state is refreshed separately via the callback).
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            if case .verified(let transaction) = verification {
                await transaction.finish()
            }
            await refreshEntitlement()
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshEntitlement()
    }
}
