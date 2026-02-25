// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import SwiftUI
#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#elseif os(tvOS) || os(watchOS)
  import UIKit
#endif

// Deprecated typealiases
@available(*, deprecated, renamed: "ColorAsset.SystemColor", message: "This typealias will be removed in SwiftGen 7.0")
public typealias AssetColorTypeAlias = ColorAsset.SystemColor
@available(*, deprecated, renamed: "ImageAsset.UniversalImage", message: "This typealias will be removed in SwiftGen 7.0")
public typealias AssetImageTypeAlias = ImageAsset.UniversalImage

// swiftlint:disable superfluous_disable_command file_length implicit_return

// MARK: - Asset Catalogs

// swiftlint:disable identifier_name line_length nesting type_body_length type_name
public enum Asset {
  public enum Assets {
    public enum Brandmarks {
      public static let brandmarkKeystone = ImageAsset(name: "brandmarkKeystone")
      public static let brandmarkLow = ImageAsset(name: "brandmarkLow")
      public static let brandmarkMax = ImageAsset(name: "brandmarkMax")
      public static let brandmarkMaxBranded = ImageAsset(name: "brandmarkMaxBranded")
      public static let brandmarkQR = ImageAsset(name: "brandmarkQR")
    }
    public static let fly = ImageAsset(name: "Fly")
    public static let flyReceived = ImageAsset(name: "FlyReceived")
    public enum Illustrations {
      public static let cone = ImageAsset(name: "cone")
      public static let connect = ImageAsset(name: "connect")
      public static let emptyState = ImageAsset(name: "emptyState")
      public static let failure1 = ImageAsset(name: "failure1")
      public static let failure2 = ImageAsset(name: "failure2")
      public static let failure3 = ImageAsset(name: "failure3")
      public static let lightning = ImageAsset(name: "lightning")
      public static let resubmission1 = ImageAsset(name: "resubmission1")
      public static let resubmission2 = ImageAsset(name: "resubmission2")
      public static let success1 = ImageAsset(name: "success1")
      public static let success2 = ImageAsset(name: "success2")
    }
    public enum Partners {
      public static let nearLogo = ImageAsset(name: "NearLogo")
      public static let coinbase = ImageAsset(name: "coinbase")
      public static let coinbaseDisabled = ImageAsset(name: "coinbaseDisabled")
      public static let coinbaseSeeklogo = ImageAsset(name: "coinbaseSeeklogo")
      public static let coinbaseSeeklogoDisabled = ImageAsset(name: "coinbaseSeeklogoDisabled")
      public static let flexa = ImageAsset(name: "flexa")
      public static let flexaDisabled = ImageAsset(name: "flexaDisabled")
      public static let flexaSeekLogo = ImageAsset(name: "flexaSeekLogo")
      public static let flexaSeeklogoDisabled = ImageAsset(name: "flexaSeeklogoDisabled")
      public static let keystone = ImageAsset(name: "keystone")
      public static let keystoneLogo = ImageAsset(name: "keystoneLogo")
      public static let keystonePromo = ImageAsset(name: "keystonePromo")
      public static let keystoneSeekLogo = ImageAsset(name: "keystoneSeekLogo")
      public static let keystoneTitleLogo = ImageAsset(name: "keystoneTitleLogo")
      public static let payWithNear = ImageAsset(name: "payWithNear")
      public static let payWithNearDisabled = ImageAsset(name: "payWithNearDisabled")
      public static let swapAndPay = ImageAsset(name: "swapAndPay")
      public static let torLogo = ImageAsset(name: "torLogo")
    }
    public static let splashHi = ImageAsset(name: "SplashHi")
    public enum Tickers {
      public static let near = ImageAsset(name: "near")
      public static let nearChain = ImageAsset(name: "nearChain")
      public static let `none` = ImageAsset(name: "none")
    }
    public static let welcomeScreenLogo = ImageAsset(name: "WelcomeScreenLogo")
    public static let zashiLogo = ImageAsset(name: "ZashiLogo")
    public static let alertIcon = ImageAsset(name: "alertIcon")
    public static let arrowLeftLong = ImageAsset(name: "arrowLeftLong")
    public static let buttonCloseX = ImageAsset(name: "buttonCloseX")
    public static let check = ImageAsset(name: "check")
    public static let chevronDown = ImageAsset(name: "chevronDown")
    public static let chevronRight = ImageAsset(name: "chevronRight")
    public static let chevronUp = ImageAsset(name: "chevronUp")
    public static let convertIcon = ImageAsset(name: "convertIcon")
    public static let copy = ImageAsset(name: "copy")
    public static let eyeOff = ImageAsset(name: "eyeOff")
    public static let eyeOn = ImageAsset(name: "eyeOn")
    public static let flyReceivedFilled = ImageAsset(name: "flyReceivedFilled")
    public enum Icons {
      public static let alertCircle = ImageAsset(name: "alertCircle")
      public static let alertOutline = ImageAsset(name: "alertOutline")
      public static let alertTriangle = ImageAsset(name: "alertTriangle")
      public static let archive = ImageAsset(name: "archive")
      public static let arrowDown = ImageAsset(name: "arrowDown")
      public static let arrowNarrowLeft = ImageAsset(name: "arrowNarrowLeft")
      public static let arrowRight = ImageAsset(name: "arrowRight")
      public static let arrowUp = ImageAsset(name: "arrowUp")
      public static let authKey = ImageAsset(name: "authKey")
      public static let bookmark = ImageAsset(name: "bookmark")
      public static let bookmarkCheck = ImageAsset(name: "bookmarkCheck")
      public static let calendar = ImageAsset(name: "calendar")
      public static let checkSolid = ImageAsset(name: "checkSolid")
      public static let coinsHand = ImageAsset(name: "coinsHand")
      public static let coinsSwap = ImageAsset(name: "coinsSwap")
      public static let connectWallet = ImageAsset(name: "connectWallet")
      public static let cryptocurrency = ImageAsset(name: "cryptocurrency")
      public static let currencyDollar = ImageAsset(name: "currencyDollar")
      public static let currencyZec = ImageAsset(name: "currencyZec")
      public static let delete = ImageAsset(name: "delete")
      public static let dotsMenu = ImageAsset(name: "dotsMenu")
      public static let downloadCloud = ImageAsset(name: "downloadCloud")
      public static let emptyShield = ImageAsset(name: "emptyShield")
      public static let expand = ImageAsset(name: "expand")
      public static let file = ImageAsset(name: "file")
      public static let filter = ImageAsset(name: "filter")
      public static let flashOff = ImageAsset(name: "flashOff")
      public static let flashOn = ImageAsset(name: "flashOn")
      public static let help = ImageAsset(name: "help")
      public static let imageLibrary = ImageAsset(name: "imageLibrary")
      public static let integrations = ImageAsset(name: "integrations")
      public static let key = ImageAsset(name: "key")
      public static let loading = ImageAsset(name: "loading")
      public static let lockLocked = ImageAsset(name: "lockLocked")
      public static let lockUnlocked = ImageAsset(name: "lockUnlocked")
      public static let logOut = ImageAsset(name: "logOut")
      public static let magicWand = ImageAsset(name: "magicWand")
      public static let menu = ImageAsset(name: "menu")
      public static let messageSmile = ImageAsset(name: "messageSmile")
      public static let noMessage = ImageAsset(name: "noMessage")
      public static let noTransactions = ImageAsset(name: "noTransactions")
      public static let partial = ImageAsset(name: "partial")
      public static let pay = ImageAsset(name: "pay")
      public static let pencil = ImageAsset(name: "pencil")
      public static let plus = ImageAsset(name: "plus")
      public static let powerOff = ImageAsset(name: "powerOff")
      public static let qr = ImageAsset(name: "qr")
      public static let received = ImageAsset(name: "received")
      public static let refreshSingleCCW = ImageAsset(name: "refreshSingleCCW")
      public static let save = ImageAsset(name: "save")
      public static let scan = ImageAsset(name: "scan")
      public static let search = ImageAsset(name: "search")
      public static let sent = ImageAsset(name: "sent")
      public static let server = ImageAsset(name: "server")
      public static let settings = ImageAsset(name: "settings")
      public static let settings2 = ImageAsset(name: "settings2")
      public static let share = ImageAsset(name: "share")
      public static let shieldBcg = ImageAsset(name: "shieldBcg")
      public static let shieldOff = ImageAsset(name: "shieldOff")
      public static let shieldOffSolid = ImageAsset(name: "shieldOffSolid")
      public static let shieldTickFilled = ImageAsset(name: "shieldTickFilled")
      public static let shieldZap = ImageAsset(name: "shieldZap")
      public static let shoppingBag = ImageAsset(name: "shoppingBag")
      public static let slippage = ImageAsset(name: "slippage")
      public static let swap = ImageAsset(name: "swap")
      public static let swapArrows = ImageAsset(name: "swapArrows")
      public static let swapTransaction = ImageAsset(name: "swapTransaction")
      public static let switchHorizontal = ImageAsset(name: "switchHorizontal")
      public static let terms = ImageAsset(name: "terms")
      public static let textInput = ImageAsset(name: "textInput")
      public static let trIn = ImageAsset(name: "trIn")
      public static let trOut = ImageAsset(name: "trOut")
      public static let trPaid = ImageAsset(name: "trPaid")
      public static let user = ImageAsset(name: "user")
      public static let userPlus = ImageAsset(name: "userPlus")
      public static let wifiOff = ImageAsset(name: "wifiOff")
      public static let xClose = ImageAsset(name: "xClose")
      public static let zashiLogoSq = ImageAsset(name: "zashiLogoSq")
      public static let zashiLogoSqBold = ImageAsset(name: "zashiLogoSqBold")
    }
    public static let infoCircle = ImageAsset(name: "infoCircle")
    public static let infoOutline = ImageAsset(name: "infoOutline")
    public static let prevZashiLogo = ImageAsset(name: "prevZashiLogo")
    public static let qrcodeScannerErr = ImageAsset(name: "qrcodeScannerErr")
    public static let rateIcons = ImageAsset(name: "rateIcons")
    public static let refreshCCW = ImageAsset(name: "refreshCCW")
    public static let refreshCCW2 = ImageAsset(name: "refreshCCW2")
    public static let restoreInfo = ImageAsset(name: "restoreInfo")
    public static let scanMark = ImageAsset(name: "scanMark")
    public static let send = ImageAsset(name: "send")
    public static let shield = ImageAsset(name: "shield")
    public static let shieldTick = ImageAsset(name: "shieldTick")
    public static let surroundedShield = ImageAsset(name: "surroundedShield")
    public static let tooltip = ImageAsset(name: "tooltip")
    public static let zashiTitle = ImageAsset(name: "zashiTitle")
  }
  public enum Colors {
    public enum ZDesign {
      public enum Base {
        public static let black = ColorAsset(name: "Black")
        public static let bone = ColorAsset(name: "Bone")
        public static let brand = ColorAsset(name: "Brand")
        public static let concrete = ColorAsset(name: "Concrete")
        public static let espresso = ColorAsset(name: "Espresso")
        public static let midnight = ColorAsset(name: "Midnight")
        public static let obsidian = ColorAsset(name: "Obsidian")
      }
      public static let brand100 = ColorAsset(name: "Brand100")
      public static let brand200 = ColorAsset(name: "Brand200")
      public static let brand25 = ColorAsset(name: "Brand25")
      public static let brand300 = ColorAsset(name: "Brand300")
      public static let brand400 = ColorAsset(name: "Brand400")
      public static let brand50 = ColorAsset(name: "Brand50")
      public static let brand500 = ColorAsset(name: "Brand500")
      public static let brand600 = ColorAsset(name: "Brand600")
      public static let brand700 = ColorAsset(name: "Brand700")
      public static let brand800 = ColorAsset(name: "Brand800")
      public static let brand900 = ColorAsset(name: "Brand900")
      public static let brand950 = ColorAsset(name: "Brand950")
      public static let errorRed100 = ColorAsset(name: "ErrorRed100")
      public static let errorRed200 = ColorAsset(name: "ErrorRed200")
      public static let errorRed25 = ColorAsset(name: "ErrorRed25")
      public static let errorRed300 = ColorAsset(name: "ErrorRed300")
      public static let errorRed400 = ColorAsset(name: "ErrorRed400")
      public static let errorRed50 = ColorAsset(name: "ErrorRed50")
      public static let errorRed500 = ColorAsset(name: "ErrorRed500")
      public static let errorRed600 = ColorAsset(name: "ErrorRed600")
      public static let errorRed700 = ColorAsset(name: "ErrorRed700")
      public static let errorRed800 = ColorAsset(name: "ErrorRed800")
      public static let errorRed900 = ColorAsset(name: "ErrorRed900")
      public static let errorRed950 = ColorAsset(name: "ErrorRed950")
      public static let espresso100 = ColorAsset(name: "Espresso100")
      public static let espresso200 = ColorAsset(name: "Espresso200")
      public static let espresso25 = ColorAsset(name: "Espresso25")
      public static let espresso300 = ColorAsset(name: "Espresso300")
      public static let espresso400 = ColorAsset(name: "Espresso400")
      public static let espresso50 = ColorAsset(name: "Espresso50")
      public static let espresso500 = ColorAsset(name: "Espresso500")
      public static let espresso600 = ColorAsset(name: "Espresso600")
      public static let espresso700 = ColorAsset(name: "Espresso700")
      public static let espresso800 = ColorAsset(name: "Espresso800")
      public static let espresso900 = ColorAsset(name: "Espresso900")
      public static let espresso950 = ColorAsset(name: "Espresso950")
      public static let gray100 = ColorAsset(name: "Gray100")
      public static let gray200 = ColorAsset(name: "Gray200")
      public static let gray25 = ColorAsset(name: "Gray25")
      public static let gray300 = ColorAsset(name: "Gray300")
      public static let gray400 = ColorAsset(name: "Gray400")
      public static let gray50 = ColorAsset(name: "Gray50")
      public static let gray500 = ColorAsset(name: "Gray500")
      public static let gray600 = ColorAsset(name: "Gray600")
      public static let gray700 = ColorAsset(name: "Gray700")
      public static let gray800 = ColorAsset(name: "Gray800")
      public static let gray900 = ColorAsset(name: "Gray900")
      public static let gray950 = ColorAsset(name: "Gray950")
      public static let hyperBlue100 = ColorAsset(name: "HyperBlue100")
      public static let hyperBlue200 = ColorAsset(name: "HyperBlue200")
      public static let hyperBlue25 = ColorAsset(name: "HyperBlue25")
      public static let hyperBlue300 = ColorAsset(name: "HyperBlue300")
      public static let hyperBlue400 = ColorAsset(name: "HyperBlue400")
      public static let hyperBlue50 = ColorAsset(name: "HyperBlue50")
      public static let hyperBlue500 = ColorAsset(name: "HyperBlue500")
      public static let hyperBlue600 = ColorAsset(name: "HyperBlue600")
      public static let hyperBlue700 = ColorAsset(name: "HyperBlue700")
      public static let hyperBlue800 = ColorAsset(name: "HyperBlue800")
      public static let hyperBlue900 = ColorAsset(name: "HyperBlue900")
      public static let hyperBlue950 = ColorAsset(name: "HyperBlue950")
      public static let indigo100 = ColorAsset(name: "Indigo100")
      public static let indigo200 = ColorAsset(name: "Indigo200")
      public static let indigo25 = ColorAsset(name: "Indigo25")
      public static let indigo300 = ColorAsset(name: "Indigo300")
      public static let indigo400 = ColorAsset(name: "Indigo400")
      public static let indigo50 = ColorAsset(name: "Indigo50")
      public static let indigo500 = ColorAsset(name: "Indigo500")
      public static let indigo600 = ColorAsset(name: "Indigo600")
      public static let indigo700 = ColorAsset(name: "Indigo700")
      public static let indigo800 = ColorAsset(name: "Indigo800")
      public static let indigo900 = ColorAsset(name: "Indigo900")
      public static let indigo950 = ColorAsset(name: "Indigo950")
      public static let purple100 = ColorAsset(name: "Purple100")
      public static let purple200 = ColorAsset(name: "Purple200")
      public static let purple25 = ColorAsset(name: "Purple25")
      public static let purple300 = ColorAsset(name: "Purple300")
      public static let purple400 = ColorAsset(name: "Purple400")
      public static let purple50 = ColorAsset(name: "Purple50")
      public static let purple500 = ColorAsset(name: "Purple500")
      public static let purple600 = ColorAsset(name: "Purple600")
      public static let purple700 = ColorAsset(name: "Purple700")
      public static let purple800 = ColorAsset(name: "Purple800")
      public static let purple900 = ColorAsset(name: "Purple900")
      public static let purple950 = ColorAsset(name: "Purple950")
      public static let shark100 = ColorAsset(name: "Shark100")
      public static let shark200 = ColorAsset(name: "Shark200")
      public static let shark25 = ColorAsset(name: "Shark25")
      public static let shark300 = ColorAsset(name: "Shark300")
      public static let shark400 = ColorAsset(name: "Shark400")
      public static let shark50 = ColorAsset(name: "Shark50")
      public static let shark500 = ColorAsset(name: "Shark500")
      public static let shark600 = ColorAsset(name: "Shark600")
      public static let shark700 = ColorAsset(name: "Shark700")
      public static let shark800 = ColorAsset(name: "Shark800")
      public static let shark900 = ColorAsset(name: "Shark900")
      public static let shark950 = ColorAsset(name: "Shark950")
      public static let sharkShades00dp = ColorAsset(name: "SharkShades00dp")
      public static let sharkShades01dp = ColorAsset(name: "SharkShades01dp")
      public static let sharkShades02dp = ColorAsset(name: "SharkShades02dp")
      public static let sharkShades03dp = ColorAsset(name: "SharkShades03dp")
      public static let sharkShades04dp = ColorAsset(name: "SharkShades04dp")
      public static let sharkShades06dp = ColorAsset(name: "SharkShades06dp")
      public static let sharkShades08dp = ColorAsset(name: "SharkShades08dp")
      public static let sharkShades12dp = ColorAsset(name: "SharkShades12dp")
      public static let sharkShades16dp = ColorAsset(name: "SharkShades16dp")
      public static let sharkShades24dp = ColorAsset(name: "SharkShades24dp")
      public static let successGreen100 = ColorAsset(name: "SuccessGreen100")
      public static let successGreen200 = ColorAsset(name: "SuccessGreen200")
      public static let successGreen25 = ColorAsset(name: "SuccessGreen25")
      public static let successGreen300 = ColorAsset(name: "SuccessGreen300")
      public static let successGreen400 = ColorAsset(name: "SuccessGreen400")
      public static let successGreen50 = ColorAsset(name: "SuccessGreen50")
      public static let successGreen500 = ColorAsset(name: "SuccessGreen500")
      public static let successGreen600 = ColorAsset(name: "SuccessGreen600")
      public static let successGreen700 = ColorAsset(name: "SuccessGreen700")
      public static let successGreen800 = ColorAsset(name: "SuccessGreen800")
      public static let successGreen900 = ColorAsset(name: "SuccessGreen900")
      public static let successGreen950 = ColorAsset(name: "SuccessGreen950")
      public static let warningYellow100 = ColorAsset(name: "WarningYellow100")
      public static let warningYellow200 = ColorAsset(name: "WarningYellow200")
      public static let warningYellow25 = ColorAsset(name: "WarningYellow25")
      public static let warningYellow300 = ColorAsset(name: "WarningYellow300")
      public static let warningYellow400 = ColorAsset(name: "WarningYellow400")
      public static let warningYellow50 = ColorAsset(name: "WarningYellow50")
      public static let warningYellow500 = ColorAsset(name: "WarningYellow500")
      public static let warningYellow600 = ColorAsset(name: "WarningYellow600")
      public static let warningYellow700 = ColorAsset(name: "WarningYellow700")
      public static let warningYellow800 = ColorAsset(name: "WarningYellow800")
      public static let warningYellow900 = ColorAsset(name: "WarningYellow900")
      public static let warningYellow950 = ColorAsset(name: "WarningYellow950")
    }
    public static let background = ColorAsset(name: "background")
    public static let btnDarkShade = ColorAsset(name: "btnDarkShade")
    public static let btnLabelShade = ColorAsset(name: "btnLabelShade")
    public static let btnLightShade = ColorAsset(name: "btnLightShade")
    public static let btnPrimary = ColorAsset(name: "btnPrimary")
    public static let btnSecondary = ColorAsset(name: "btnSecondary")
    public static let messageBcgBorder = ColorAsset(name: "messageBcgBorder")
    public static let messageBcgDisabled = ColorAsset(name: "messageBcgDisabled")
    public static let messageBcgReceived = ColorAsset(name: "messageBcgReceived")
    public static let pickerBcg = ColorAsset(name: "pickerBcg")
    public static let pickerSelection = ColorAsset(name: "pickerSelection")
    public static let pickerTitleSelected = ColorAsset(name: "pickerTitleSelected")
    public static let pickerTitleUnselected = ColorAsset(name: "pickerTitleUnselected")
    public static let primary = ColorAsset(name: "primary")
    public static let restoreUI = ColorAsset(name: "restoreUI")
    public static let secondary = ColorAsset(name: "secondary")
    public static let shade30 = ColorAsset(name: "shade30")
    public static let shade47 = ColorAsset(name: "shade47")
    public static let shade55 = ColorAsset(name: "shade55")
    public static let shade72 = ColorAsset(name: "shade72")
    public static let shade85 = ColorAsset(name: "shade85")
    public static let shade92 = ColorAsset(name: "shade92")
    public static let shade97 = ColorAsset(name: "shade97")
    public static let splash = ColorAsset(name: "splash")
    public static let syncProgresBcg = ColorAsset(name: "syncProgresBcg")
  }
}
// swiftlint:enable identifier_name line_length nesting type_body_length type_name

// MARK: - Implementation Details

public final class ColorAsset {
  public fileprivate(set) var name: String

  #if os(macOS)
  public typealias SystemColor = NSColor
  #elseif os(iOS) || os(tvOS) || os(watchOS)
  public typealias SystemColor = UIColor
  #endif

  @available(iOS 11.0, tvOS 11.0, watchOS 4.0, macOS 10.13, *)
  public private(set) lazy var systemColor: SystemColor = {
    guard let color = SystemColor(asset: self) else {
      fatalError("Unable to load color asset named \(name).")
    }
    return color
  }()

  public private(set) lazy var color: Color = {
    Color(systemColor)
  }()

  fileprivate init(name: String) {
    self.name = name
  }
}

public extension ColorAsset.SystemColor {
  @available(iOS 11.0, tvOS 11.0, watchOS 4.0, macOS 10.13, *)
  convenience init?(asset: ColorAsset) {
    let bundle = BundleToken.bundle
    #if os(iOS) || os(tvOS)
    self.init(named: asset.name, in: bundle, compatibleWith: nil)
    #elseif os(macOS)
    self.init(named: NSColor.Name(asset.name), bundle: bundle)
    #elseif os(watchOS)
    self.init(named: asset.name)
    #endif
  }
}

public struct ImageAsset {
  public fileprivate(set) var name: String

  #if os(macOS)
  public typealias UniversalImage = NSImage
  #elseif os(iOS) || os(tvOS) || os(watchOS)
  public typealias UniversalImage = UIImage
  #endif

  public var systemImage: UniversalImage {
    let bundle = BundleToken.bundle
    #if os(iOS) || os(tvOS)
    let image = UniversalImage(named: name, in: bundle, compatibleWith: nil)
    #elseif os(macOS)
    let name = NSImage.Name(self.name)
    let image = (bundle == .main) ? NSImage(named: name) : bundle.image(forResource: name)
    #elseif os(watchOS)
    let image = UniversalImage(named: name)
    #endif
    guard let result = image else {
      fatalError("Unable to load image asset named \(name).")
    }
    return result
  }

  public var image: Image {
    let bundle = BundleToken.bundle
    return Image(name, bundle: bundle)
  }
}

public extension ImageAsset.UniversalImage {
  @available(macOS, deprecated,
    message: "This initializer is unsafe on macOS, please use the ImageAsset.image property")
  convenience init?(asset: ImageAsset) {
    #if os(iOS) || os(tvOS)
    let bundle = BundleToken.bundle
    self.init(named: asset.name, in: bundle, compatibleWith: nil)
    #elseif os(macOS)
    self.init(named: NSImage.Name(asset.name))
    #elseif os(watchOS)
    self.init(named: asset.name)
    #endif
  }
}

// swiftlint:disable convenience_type
private final class BundleToken {
  static let bundle: Bundle = {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle(for: BundleToken.self)
    #endif
  }()
}

// swiftlint:enable convenience_type

extension ColorAsset: @unchecked Sendable { }
extension ImageAsset: @unchecked Sendable { }
// swiftlint:enable all
