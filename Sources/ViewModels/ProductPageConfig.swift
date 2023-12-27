//
//  EditProductPageViewModel.swift
//
//  Created by Henadzi Rabkin on 08/10/2023.
//
import SwiftUI

enum ProductPageType {
    case view, new
}

enum ProductPageState: Sendable {
    case loading, completed, productDetails, error
}

final class ProductPageConfig: ObservableObject {
    
    static let requiredNutrients = ["energy-kcal", "proteins", "carbohydrates", "fat"]
    static let requiredImageFields = [ ImageField.front, ImageField.nutrition ]
    
    @Published var pageState = ProductPageState.loading
    
    @Published var pageType = ProductPageType.view // TODO: workaround until editing will be implemented
    {
        didSet {
            print("PageType set to \(pageType)")
        }
    }
    
    @Published var nutrientsMeta: NutrientMetadata?
    @Published var orderedNutrients: [OrderedNutrient] = []
    
    @Published var isInitialised: Bool = false
    @Published var isProductJustUploaded: Bool = false
    
    @Published var productName = ""
    @Published var brand = ""
    @Published var categories: [String] = []
    @Published var weight = ""
    @Published var servingSize = ""
    @Published var selectedNutrients: Set<String> = [] // ids
    @Published var dataFor = DataFor.hundredG
    @Published var packageLanguage = OFFConfig.shared.productsLanguage {
        didSet {
            OFFConfig.shared.productsLanguage = packageLanguage
            print("Package language update to \(OFFConfig.shared.productsLanguage)")
        }
    }
    @Published var images = Dictionary(uniqueKeysWithValues: ImageField.allCases.map { ($0, UIImage()) })
    
    @Published var errorMessage: ErrorAlert?
    @Published var submittedProduct: [String: String]? = nil
    
    func binding(for key: ImageField) -> Binding<UIImage> {
        return Binding<UIImage>(
            get: { self.images[key] ?? UIImage() },
            set: { newValue in self.images[key] = newValue }
        )
    }
    
    var isViewMode: Bool {
        return pageType == .view
    }
    var isNewMode: Bool {
        return pageType == .new
    }
    
    func fetchData(barcode: String) async {
        
        await MainActor.run {
            self.pageState = .loading
        }
        
        do {
            async let taskOrderedNutrients = OpenFoodAPIClient.shared.getOrderedNutrients()
            async let taskProductResponse = OpenFoodAPIClient.shared.getProduct(config: ProductQueryConfiguration(barcode: barcode))
            async let taskNutrientsMeta = OpenFoodAPIClient.shared.fetchNutrientsMetadata()

            let orderedNutrients = try await taskOrderedNutrients
            let productResponse = try await taskProductResponse
            let nutrientsMeta = try await taskNutrientsMeta
            
            let pageType = await determinePageType(response: productResponse)
            
            await MainActor.run {
                self.pageState = .completed
                self.orderedNutrients = orderedNutrients
                self.nutrientsMeta = nutrientsMeta
                self.isInitialised = true
                self.pageType = pageType
            }
            try await Task.sleep(nanoseconds: 1_000_000_000 * UInt64(PageOverlay.completedAnimDuration))
            await MainActor.run {
                self.pageState = .productDetails
            }
            
        } catch {
            await MainActor.run {
                self.pageState = .error
                self.errorMessage = ErrorAlert(message: error.localizedDescription, title: "Error")
            }
        }
    }
    
    func determinePageType(response: ProductResponse) async -> ProductPageType {
        if response.hasProduct(), let product = response.product {
            await self.unwrapExistingProduct(product: product)
            return ProductPageType.view
        }
        return ProductPageType.new
    }
    
    /// Bare minimum marked with .required() view modifier
    func getMissingFields() -> [String] {
        
        if !OFFConfig.shared.useRequired { return [] }
        
        var missingFields = [String]()
        
        if productName.isEmpty { missingFields.append("Name") }
        if weight.isEmpty { missingFields.append("Weight") }
        if images[ImageField.front]!.isEmpty() { missingFields.append("Front image") }
        if images[ImageField.nutrition]!.isEmpty() { missingFields.append("Nutrients image") }
        
        return missingFields
    }
    
    func getMissingFieldsMessage() -> String {
        return getMissingFields().map { "'\($0)'" }.joined(separator: ", ")
    }
    
    @MainActor
    func unwrapExistingProduct(product: Product) async {
        
        self.productName = product.productName ?? ""
        self.brand = product.brands ?? ""
        
        if let cats = product.categories {
            self.categories = [ cats ]
        }
        self.weight = product.quantity ?? ""
        self.servingSize = product.servingSize ?? ""
        
        self.dataFor = DataFor(rawValue: product.dataPer ?? "") ?? DataFor.hundredG
        self.packageLanguage = product.lang ?? OpenFoodFactsLanguage.UNDEFINED
        
        if let productNutrients = product.nutriments {
            for on in orderedNutrients {
                let key = "\(on.id)_\(self.dataFor.rawValue)"
                let unitKey = "\(on.id)_unit"
                
                if productNutrients.keys.contains(unitKey), 
                    let unitStr = productNutrients[unitKey] as? String,
                    let unit = Unit(fromString: unitStr) {
                    on.currentUnit = unit
                }
                let hasKey = productNutrients.keys.contains(key)
                if hasKey, let value = productNutrients[key] as? Double {
                    on.value = on.convertWeightToG(value).toString()
                }
                on.displayInEditForm = hasKey
                on.important = hasKey
                if hasKey {
                    selectedNutrients.insert(on.id)
                }
            }
        }
        
        let imageUrls = [
            ImageField.front: product.imageFront,
            ImageField.ingredients: product.imageIngredients,
            ImageField.nutrition: product.imageNutrition
        ]
        do {
            self.images = try await OpenFoodAPIClient.shared.fetchProductImages(imageUrls: imageUrls)
        } catch {
            print("\(#function) failed to unwrap some images, \(error)")
            // Non critical error, no need to show to user
        }
    }
    
    @MainActor
    func uploadAllProductData(barcode: String) async {
        
        pageState = .loading
        
        do {
            try await sendAllImages(barcode: barcode)
        } catch {
            // Not critical
            // TODO: after incremental save is supported update this
            print("Some images failed to upload: \(error.localizedDescription)")
        }
        var product = [String: String]()
        do {
            product = try await composeProduct(barcode: barcode)
            try await OpenFoodAPIClient.shared.saveProduct(product: product)
        } catch {
            self.pageState = .error
            self.errorMessage = ErrorAlert(message: "Could not save product \(error.localizedDescription)", title: "Error")
        }
        
        self.pageState = .completed
        DispatchQueue.main.asyncAfter(deadline: .now() + PageOverlay.completedAnimDuration) {
            self.pageState = ProductPageState.productDetails
            self.isProductJustUploaded = true
            self.submittedProduct = product
        }
    }
    
    private func composeProduct(barcode: String) async throws -> [String: String] {
        
        var product = [
            "code": barcode,
            "product_name": self.productName,
            "brands": brand,
            "lang": OFFConfig.shared.productsLanguage.info.code,
            "quantity": self.weight,
            "serving_size": self.servingSize,
            "nutrition_data_per": self.dataFor.rawValue,
            "categories": categories.joined(separator: ",")
        ]
        
        let productNutrients = orderedNutrients.filter { selectedNutrients.contains($0.id) }
        let nuntrients = productNutrients.reduce(into: [String: String]()) { (result, element) in
            let value = element.value.isEmpty ? "0,0" : element.value
            result["nutriment_\(element.id)"] = value
            result["nutriment_\(element.id)_unit"] = element.currentUnit.rawValue
        }
        product.merge(nuntrients) { (current, _) in current }
        
        return product
    }
    
    private func sendAllImages(barcode: String) async throws {
        
        let sendImages = self.images.reduce(into: [SendImage]()) { (result, element) in
            if !element.value.isEmpty() {
                result.append(SendImage(barcode: barcode, imageField: element.key, image: element.value))
            }
        }
        
        await withThrowingTaskGroup(of: Void.self) { group in
            sendImages.forEach { image in
                group.addTask {
                    try await OpenFoodAPIClient.shared.addProductImage(imageData: image)
                }
            }
        }
    }
}
