// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// swiftlint:disable superfluous_disable_command file_length implicit_return prefer_self_in_static_references

// MARK: - Strings

// swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
public enum L10n {
  /// QR Code for %@
  public static func qrCodeFor(_ p1: Any) -> String {
    return L10n.tr("Localizable", "qrCodeFor", String(describing: p1), fallback: "QR Code for %@")
  }
  /// on
  public static let tokenOnChain = L10n.tr("Localizable", "tokenOnChain", fallback: "on")
  public enum About {
    /// Developed by the team that set the industry standard for onchain privacy, the original developers of the Zcash protocol.
    public static let additionalInfo = L10n.tr("Localizable", "about.additionalInfo", fallback: "Developed by the team that set the industry standard for onchain privacy, the original developers of the Zcash protocol.")
    /// Zodl is a Zcash-powered mobile wallet, built for unstoppable private payments. It’s optimized for storage and real-world use of shielded $ZEC—the truly private cryptocurrency.
    public static let info = L10n.tr("Localizable", "about.info", fallback: "Zodl is a Zcash-powered mobile wallet, built for unstoppable private payments. It’s optimized for storage and real-world use of shielded $ZEC—the truly private cryptocurrency.")
    /// Privacy Policy
    public static let privacyPolicy = L10n.tr("Localizable", "about.privacyPolicy", fallback: "Privacy Policy")
    /// Terms of Service
    public static let termsOfUse = L10n.tr("Localizable", "about.termsOfUse", fallback: "Terms of Service")
    /// Introducing Zodl
    public static let title = L10n.tr("Localizable", "about.title", fallback: "Introducing Zodl")
  }
  public enum Accounts {
    /// Keystone
    public static let keystone = L10n.tr("Localizable", "accounts.keystone", fallback: "Keystone")
    /// Send from
    public static let sendingFrom = L10n.tr("Localizable", "accounts.sendingFrom", fallback: "Send from")
    /// Zodl
    public static let zashi = L10n.tr("Localizable", "accounts.zashi", fallback: "Zodl")
    public enum AddressBook {
      /// Address Book Contacts
      public static let contacts = L10n.tr("Localizable", "accounts.addressBook.contacts", fallback: "Address Book Contacts")
      /// Your Wallets
      public static let your = L10n.tr("Localizable", "accounts.addressBook.your", fallback: "Your Wallets")
    }
    public enum Keystone {
      /// Zcash Shielded Address
      public static let shieldedAddress = L10n.tr("Localizable", "accounts.keystone.shieldedAddress", fallback: "Zcash Shielded Address")
      /// Zcash Transparent Address
      public static let transparentAddress = L10n.tr("Localizable", "accounts.keystone.transparentAddress", fallback: "Zcash Transparent Address")
    }
    public enum Zashi {
      /// Zcash Shielded Address
      public static let shieldedAddress = L10n.tr("Localizable", "accounts.zashi.shieldedAddress", fallback: "Zcash Shielded Address")
      /// Zcash Transparent Address
      public static let transparentAddress = L10n.tr("Localizable", "accounts.zashi.transparentAddress", fallback: "Zcash Transparent Address")
    }
  }
  public enum AddressBook {
    /// Add New Contact
    public static let addNewContact = L10n.tr("Localizable", "addressBook.addNewContact", fallback: "Add New Contact")
    /// Your address book is empty
    public static let empty = L10n.tr("Localizable", "addressBook.empty", fallback: "Your address book is empty")
    /// Manual Entry
    public static let manualEntry = L10n.tr("Localizable", "addressBook.manualEntry", fallback: "Manual Entry")
    /// Saved Address
    public static let savedAddress = L10n.tr("Localizable", "addressBook.savedAddress", fallback: "Saved Address")
    /// Scan QR code
    public static let scanAddress = L10n.tr("Localizable", "addressBook.scanAddress", fallback: "Scan QR code")
    /// Select recipient
    public static let selectRecipient = L10n.tr("Localizable", "addressBook.selectRecipient", fallback: "Select recipient")
    /// Address Book
    public static let title = L10n.tr("Localizable", "addressBook.title", fallback: "Address Book")
    public enum Alert {
      /// You are about to delete this contact. This cannot be undone.
      public static let message = L10n.tr("Localizable", "addressBook.alert.message", fallback: "You are about to delete this contact. This cannot be undone.")
      /// Are you sure?
      public static let title = L10n.tr("Localizable", "addressBook.alert.title", fallback: "Are you sure?")
    }
    public enum Error {
      /// An address with this chain is already in your Address Book.
      public static let addressExists = L10n.tr("Localizable", "addressBook.error.addressExists", fallback: "An address with this chain is already in your Address Book.")
      /// Invalid address.
      public static let invalidAddress = L10n.tr("Localizable", "addressBook.error.invalidAddress", fallback: "Invalid address.")
      /// This contact name is already in use. Please choose a different name.
      public static let nameExists = L10n.tr("Localizable", "addressBook.error.nameExists", fallback: "This contact name is already in use. Please choose a different name.")
      /// This contact name exceeds the 32-character limit. Please shorten the name.
      public static let nameLength = L10n.tr("Localizable", "addressBook.error.nameLength", fallback: "This contact name exceeds the 32-character limit. Please shorten the name.")
    }
    public enum NewContact {
      /// Wallet Address
      public static let address = L10n.tr("Localizable", "addressBook.newContact.address", fallback: "Wallet Address")
      /// Enter wallet address...
      public static let addressPlaceholder = L10n.tr("Localizable", "addressBook.newContact.addressPlaceholder", fallback: "Enter wallet address...")
      /// Contact Name
      public static let name = L10n.tr("Localizable", "addressBook.newContact.name", fallback: "Contact Name")
      /// Enter contact name...
      public static let namePlaceholder = L10n.tr("Localizable", "addressBook.newContact.namePlaceholder", fallback: "Enter contact name...")
      /// Add New Address
      public static let title = L10n.tr("Localizable", "addressBook.newContact.title", fallback: "Add New Address")
    }
  }
  public enum AddressDetails {
    /// Copy Address
    public static let copyAddress = L10n.tr("Localizable", "addressDetails.copyAddress", fallback: "Copy Address")
    /// Hi, scan this QR code to send me a ZEC payment!
    public static let shareDesc = L10n.tr("Localizable", "addressDetails.shareDesc", fallback: "Hi, scan this QR code to send me a ZEC payment!")
    /// Share QR Code
    public static let shareQR = L10n.tr("Localizable", "addressDetails.shareQR", fallback: "Share QR Code")
    /// My Zodl ZEC Address
    public static let shareTitle = L10n.tr("Localizable", "addressDetails.shareTitle", fallback: "My Zodl ZEC Address")
  }
  public enum Annotation {
    /// Add note
    public static let add = L10n.tr("Localizable", "annotation.add", fallback: "Add note")
    /// Add a note
    public static let addArticle = L10n.tr("Localizable", "annotation.addArticle", fallback: "Add a note")
    /// %@/%@ characters
    public static func chars(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "annotation.chars", String(describing: p1), String(describing: p2), fallback: "%@/%@ characters")
    }
    /// Delete note
    public static let delete = L10n.tr("Localizable", "annotation.delete", fallback: "Delete note")
    /// Edit a note
    public static let edit = L10n.tr("Localizable", "annotation.edit", fallback: "Edit a note")
    /// Write an optional note to describe this transaction...
    public static let placeholder = L10n.tr("Localizable", "annotation.placeholder", fallback: "Write an optional note to describe this transaction...")
    /// Save note
    public static let save = L10n.tr("Localizable", "annotation.save", fallback: "Save note")
    /// Note
    public static let title = L10n.tr("Localizable", "annotation.title", fallback: "Note")
  }
  public enum Balance {
    /// Spendable:
    public static let availableTitle = L10n.tr("Localizable", "balance.availableTitle", fallback: "Spendable:")
  }
  public enum Balances {
    /// Dismiss
    public static let dismiss = L10n.tr("Localizable", "balances.dismiss", fallback: "Dismiss")
    /// All your funds are shielded and spendable.
    public static let everythingDone = L10n.tr("Localizable", "balances.everythingDone", fallback: "All your funds are shielded and spendable.")
    /// Pending receipt of change from a prior transaction.
    public static let infoPending = L10n.tr("Localizable", "balances.infoPending", fallback: "Pending receipt of change from a prior transaction.")
    /// Shield your transparent ZEC to make it spendable and private. Doing so will create a shielding in-wallet transaction, consolidating your transparent and shielded funds. (Typical fee: %@)
    public static func infoShielding(_ p1: Any) -> String {
      return L10n.tr("Localizable", "balances.infoShielding", String(describing: p1), fallback: "Shield your transparent ZEC to make it spendable and private. Doing so will create a shielding in-wallet transaction, consolidating your transparent and shielded funds. (Typical fee: %@)")
    }
    /// Zodl is scanning the blockchain to make sure your balances are displayed correctly.
    public static let infoSyncing = L10n.tr("Localizable", "balances.infoSyncing", fallback: "Zodl is scanning the blockchain to make sure your balances are displayed correctly.")
    /// Pending
    public static let pending = L10n.tr("Localizable", "balances.pending", fallback: "Pending")
    /// The restore process can take several hours on lower-powered devices, and even on powerful devices is likely to take more than an hour.
    public static let restoringWalletWarning = L10n.tr("Localizable", "balances.restoringWalletWarning", fallback: "The restore process can take several hours on lower-powered devices, and even on powerful devices is likely to take more than an hour.")
    /// Shield and consolidate funds
    public static let shieldButtonTitle = L10n.tr("Localizable", "balances.shieldButtonTitle", fallback: "Shield and consolidate funds")
    /// Shielding
    public static let shieldingInProgress = L10n.tr("Localizable", "balances.shieldingInProgress", fallback: "Shielding")
    /// Shielded (Spendable)
    public static let spendableBalance = L10n.tr("Localizable", "balances.spendableBalance", fallback: "Shielded (Spendable)")
    /// Synced
    public static let synced = L10n.tr("Localizable", "balances.synced", fallback: "Synced")
    /// Syncing
    public static let syncing = L10n.tr("Localizable", "balances.syncing", fallback: "Syncing")
    /// Zodl encountered an error while syncing, attempting to resolve...
    public static let syncingError = L10n.tr("Localizable", "balances.syncingError", fallback: "Zodl encountered an error while syncing, attempting to resolve...")
    /// Transparent balance
    public static let transparentBalance = L10n.tr("Localizable", "balances.transparentBalance", fallback: "Transparent balance")
    public enum HintBox {
      /// I got it!
      public static let dismiss = L10n.tr("Localizable", "balances.hintBox.dismiss", fallback: "I got it!")
      /// Zodl uses the latest network upgrade and does not support sending transparent (unshielded) ZEC. Use the Shield and Consolidate button to shield your funds, which will add to your available balance and make your ZEC spendable.
      public static let message = L10n.tr("Localizable", "balances.hintBox.message", fallback: "Zodl uses the latest network upgrade and does not support sending transparent (unshielded) ZEC. Use the Shield and Consolidate button to shield your funds, which will add to your available balance and make your ZEC spendable.")
    }
    public enum SpendableBalance {
      /// Spendable Balance
      public static let title = L10n.tr("Localizable", "balances.spendableBalance.title", fallback: "Spendable Balance")
    }
  }
  public enum Coinbase {
    /// Coinbase Onramp is temporarily unavailable.
    public static let disabled = L10n.tr("Localizable", "coinbase.disabled", fallback: "Coinbase Onramp is temporarily unavailable.")
  }
  public enum Component {
    /// Not Private
    public static let lowPrivacy = L10n.tr("Localizable", "component.lowPrivacy", fallback: "Not Private")
    /// Private
    public static let maxPrivacy = L10n.tr("Localizable", "component.maxPrivacy", fallback: "Private")
  }
  public enum Crosspay {
    /// Pay
    public static let pay = L10n.tr("Localizable", "crosspay.pay", fallback: "Pay")
    /// Payment Amount
    public static let paymentAmount = L10n.tr("Localizable", "crosspay.paymentAmount", fallback: "Payment Amount")
    /// Send from
    public static let sendingFrom = L10n.tr("Localizable", "crosspay.sendingFrom", fallback: "Send from")
    /// Use shielded ZEC to send cross-chain payments.
    public static let sendPayDesc = L10n.tr("Localizable", "crosspay.sendPayDesc", fallback: "Use shielded ZEC to send cross-chain payments.")
    /// Send ZEC
    public static let sendZec = L10n.tr("Localizable", "crosspay.sendZec", fallback: "Send ZEC")
    /// Use shielded ZEC to send private Zcash payments.
    public static let sendZecDesc = L10n.tr("Localizable", "crosspay.sendZecDesc", fallback: "Use shielded ZEC to send private Zcash payments.")
    /// You may pay up to 
    public static let slippageSet1 = L10n.tr("Localizable", "crosspay.slippageSet1", fallback: "You may pay up to ")
    /// %@% (%@)
    public static func slippageSet2a(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "crosspay.slippageSet2a", String(describing: p1), String(describing: p2), fallback: "%@% (%@)")
    }
    /// %@%
    public static func slippageSet2b(_ p1: Any) -> String {
      return L10n.tr("Localizable", "crosspay.slippageSet2b", String(describing: p1), fallback: "%@%")
    }
    ///  more, in addition to transaction fees.
    public static let slippageSet3 = L10n.tr("Localizable", "crosspay.slippageSet3", fallback: " more, in addition to transaction fees.")
    /// CrossPay
    public static let title = L10n.tr("Localizable", "crosspay.title", fallback: "CrossPay")
    /// Total
    public static let total = L10n.tr("Localizable", "crosspay.total", fallback: "Total")
    public enum Help {
      /// Make cross-chain payments in any NEAR-supported coin or token.
      public static let desc1 = L10n.tr("Localizable", "crosspay.help.desc1", fallback: "Make cross-chain payments in any NEAR-supported coin or token.")
      /// If the actual slippage and network conditions result in your recipient receiving less than the promised amount, your transaction will be reversed. You will receive a full refund minus network fees.
      public static let desc2 = L10n.tr("Localizable", "crosspay.help.desc2", fallback: "If the actual slippage and network conditions result in your recipient receiving less than the promised amount, your transaction will be reversed. You will receive a full refund minus network fees.")
      /// CrossPay with
      public static let payWith = L10n.tr("Localizable", "crosspay.help.payWith", fallback: "CrossPay with")
    }
  }
  public enum CurrencyConversion {
    /// Review
    public static let cardButton = L10n.tr("Localizable", "currencyConversion.cardButton", fallback: "Review")
    /// New Feature
    public static let cardTitle = L10n.tr("Localizable", "currencyConversion.cardTitle", fallback: "New Feature")
    /// Enable
    public static let enable = L10n.tr("Localizable", "currencyConversion.enable", fallback: "Enable")
    /// If Tor Protection is enabled (Advanced Settings), Zodl protects your IP address.
    public static let ipDesc = L10n.tr("Localizable", "currencyConversion.ipDesc", fallback: "If Tor Protection is enabled (Advanced Settings), Zodl protects your IP address.")
    /// IP Address Protection
    public static let ipTitle = L10n.tr("Localizable", "currencyConversion.ipTitle", fallback: "IP Address Protection")
    /// Display your balance and payment amounts in USD. You can manage this feature in Advanced Settings.
    public static let learnMoreDesc = L10n.tr("Localizable", "currencyConversion.learnMoreDesc", fallback: "Display your balance and payment amounts in USD. You can manage this feature in Advanced Settings.")
    /// Disable
    public static let learnMoreOptionDisable = L10n.tr("Localizable", "currencyConversion.learnMoreOptionDisable", fallback: "Disable")
    /// Don’t show the currency conversion.
    public static let learnMoreOptionDisableDesc = L10n.tr("Localizable", "currencyConversion.learnMoreOptionDisableDesc", fallback: "Don’t show the currency conversion.")
    /// Show me the currency conversion.
    public static let learnMoreOptionEnableDesc = L10n.tr("Localizable", "currencyConversion.learnMoreOptionEnableDesc", fallback: "Show me the currency conversion.")
    /// Note for the super privacy-conscious: Because we pull the conversion rate from exchanges, an exchange might be able to see that the exchange rate was queried before a transaction occurred.
    public static let note = L10n.tr("Localizable", "currencyConversion.note", fallback: "Note for the super privacy-conscious: Because we pull the conversion rate from exchanges, an exchange might be able to see that the exchange rate was queried before a transaction occurred.")
    /// Rate Refresh
    public static let refresh = L10n.tr("Localizable", "currencyConversion.refresh", fallback: "Rate Refresh")
    /// The rate is refreshed automatically and can also be refreshed manually.
    public static let refreshDesc = L10n.tr("Localizable", "currencyConversion.refreshDesc", fallback: "The rate is refreshed automatically and can also be refreshed manually.")
    /// Save changes
    public static let saveBtn = L10n.tr("Localizable", "currencyConversion.saveBtn", fallback: "Save changes")
    /// Display your balance and payment amounts in USD.
    public static let settingsDesc = L10n.tr("Localizable", "currencyConversion.settingsDesc", fallback: "Display your balance and payment amounts in USD.")
    /// Skip for now
    public static let skipBtn = L10n.tr("Localizable", "currencyConversion.skipBtn", fallback: "Skip for now")
    /// Currency Conversion
    public static let title = L10n.tr("Localizable", "currencyConversion.title", fallback: "Currency Conversion")
    /// If you would like to protect your IP address, enable Tor Protection in Advanced Settings.
    public static let torOffInfo = L10n.tr("Localizable", "currencyConversion.torOffInfo", fallback: "If you would like to protect your IP address, enable Tor Protection in Advanced Settings.")
    /// Disabling Tor Protection will also disable the Currency Conversion feature until re-enabled.
    public static let torOnInfo = L10n.tr("Localizable", "currencyConversion.torOnInfo", fallback: "Disabling Tor Protection will also disable the Currency Conversion feature until re-enabled.")
  }
  public enum DeeplinkWarning {
    /// Rescan in Zodl
    public static let cta = L10n.tr("Localizable", "deeplinkWarning.cta", fallback: "Rescan in Zodl")
    /// For better safety and security, rescan the QR code with Zodl.
    public static let desc = L10n.tr("Localizable", "deeplinkWarning.desc", fallback: "For better safety and security, rescan the QR code with Zodl.")
    /// Hello!
    public static let screenTitle = L10n.tr("Localizable", "deeplinkWarning.screenTitle", fallback: "Hello!")
    /// Looks like you used a third-party app to scan for payment.
    public static let title = L10n.tr("Localizable", "deeplinkWarning.title", fallback: "Looks like you used a third-party app to scan for payment.")
  }
  public enum DeleteWallet {
    /// Reset Zodl
    public static let actionButtonTitle = L10n.tr("Localizable", "deleteWallet.actionButtonTitle", fallback: "Reset Zodl")
    /// I understand
    public static let iUnderstand = L10n.tr("Localizable", "deleteWallet.iUnderstand", fallback: "I understand")
    /// Resetting your app can lead to complete loss of access to your funds! ⚠️
    public static let message1 = L10n.tr("Localizable", "deleteWallet.message1", fallback: "Resetting your app can lead to complete loss of access to your funds! ⚠️")
    /// Make sure you have both your secret recovery phrase and wallet birthday height saved before you proceed.
    public static let message2 = L10n.tr("Localizable", "deleteWallet.message2", fallback: "Make sure you have both your secret recovery phrase and wallet birthday height saved before you proceed.")
    /// Resetting the Zodl app will delete the app database and cached app data, and disconnect all connected hardware wallets.
    public static let message3 = L10n.tr("Localizable", "deleteWallet.message3", fallback: "Resetting the Zodl app will delete the app database and cached app data, and disconnect all connected hardware wallets.")
    /// Once you Reset Zodl, the only way to access your funds is through a wallet restore process that requires your Zodl Recovery Phrase and Wallet Birthday Height.
    public static let message4 = L10n.tr("Localizable", "deleteWallet.message4", fallback: "Once you Reset Zodl, the only way to access your funds is through a wallet restore process that requires your Zodl Recovery Phrase and Wallet Birthday Height.")
    /// Keep encrypted metadata backup - which includes contacts, notes, bookmarks, and swap/payment details.
    public static let metadataWarn1 = L10n.tr("Localizable", "deleteWallet.metadataWarn1", fallback: "Keep encrypted metadata backup - which includes contacts, notes, bookmarks, and swap/payment details.")
    /// This data cannot be recovered during Restore.
    public static let metadataWarn2 = L10n.tr("Localizable", "deleteWallet.metadataWarn2", fallback: "This data cannot be recovered during Restore.")
    /// Reset
    public static let screenTitle = L10n.tr("Localizable", "deleteWallet.screenTitle", fallback: "Reset")
    /// Reset Zodl
    public static let title = L10n.tr("Localizable", "deleteWallet.title", fallback: "Reset Zodl")
    public enum Sheet {
      /// Resetting the app cannot be undone. You will need to restore your wallet using your secret recovery phrase.
      public static let msg = L10n.tr("Localizable", "deleteWallet.sheet.msg", fallback: "Resetting the app cannot be undone. You will need to restore your wallet using your secret recovery phrase.")
      /// Are you sure?
      public static let title = L10n.tr("Localizable", "deleteWallet.sheet.title", fallback: "Are you sure?")
    }
  }
  public enum EnhanceTransaction {
    /// Fetch data
    public static let btn = L10n.tr("Localizable", "enhanceTransaction.btn", fallback: "Fetch data")
    /// Transaction ID
    public static let fieldTitle = L10n.tr("Localizable", "enhanceTransaction.fieldTitle", fallback: "Transaction ID")
    /// If you confirm, Zodl will fetch transaction data for a transaction ID you provide.
    public static let msg = L10n.tr("Localizable", "enhanceTransaction.msg", fallback: "If you confirm, Zodl will fetch transaction data for a transaction ID you provide.")
    /// Enter or paste...
    public static let placeholder = L10n.tr("Localizable", "enhanceTransaction.placeholder", fallback: "Enter or paste...")
    /// Refresh Transaction Data
    public static let title = L10n.tr("Localizable", "enhanceTransaction.title", fallback: "Refresh Transaction Data")
  }
  public enum ErrorPage {
    public enum Action {
      /// Contact Support
      public static let contactSupport = L10n.tr("Localizable", "errorPage.action.contactSupport", fallback: "Contact Support")
    }
  }
  public enum ExportLogs {
    public enum Alert {
      public enum Failed {
        /// Error: %@
        public static func message(_ p1: Any) -> String {
          return L10n.tr("Localizable", "exportLogs.alert.failed.message", String(describing: p1), fallback: "Error: %@")
        }
        /// Error when exporting logs
        public static let title = L10n.tr("Localizable", "exportLogs.alert.failed.title", fallback: "Error when exporting logs")
      }
    }
  }
  public enum Filter {
    /// Apply
    public static let apply = L10n.tr("Localizable", "filter.apply", fallback: "Apply")
    /// at
    public static let at = L10n.tr("Localizable", "filter.at", fallback: "at")
    /// Bookmarked
    public static let bookmarked = L10n.tr("Localizable", "filter.bookmarked", fallback: "Bookmarked")
    /// Contact
    public static let contact = L10n.tr("Localizable", "filter.contact", fallback: "Contact")
    /// %@ days ago
    public static func daysAgo(_ p1: Any) -> String {
      return L10n.tr("Localizable", "filter.daysAgo", String(describing: p1), fallback: "%@ days ago")
    }
    /// Memos
    public static let memos = L10n.tr("Localizable", "filter.memos", fallback: "Memos")
    /// No results
    public static let noResults = L10n.tr("Localizable", "filter.noResults", fallback: "No results")
    /// Notes
    public static let notes = L10n.tr("Localizable", "filter.notes", fallback: "Notes")
    /// Previous 30 days
    public static let previous30days = L10n.tr("Localizable", "filter.previous30days", fallback: "Previous 30 days")
    /// Previous 7 days
    public static let previous7days = L10n.tr("Localizable", "filter.previous7days", fallback: "Previous 7 days")
    /// Received
    public static let received = L10n.tr("Localizable", "filter.received", fallback: "Received")
    /// Reset
    public static let reset = L10n.tr("Localizable", "filter.reset", fallback: "Reset")
    /// Search
    public static let search = L10n.tr("Localizable", "filter.search", fallback: "Search")
    /// Sent
    public static let sent = L10n.tr("Localizable", "filter.sent", fallback: "Sent")
    /// Swaps
    public static let swap = L10n.tr("Localizable", "filter.swap", fallback: "Swaps")
    /// Filter
    public static let title = L10n.tr("Localizable", "filter.title", fallback: "Filter")
    /// Today
    public static let today = L10n.tr("Localizable", "filter.today", fallback: "Today")
    /// We tried but couldn’t find anything.
    public static let weTried = L10n.tr("Localizable", "filter.weTried", fallback: "We tried but couldn’t find anything.")
    /// Yesterday
    public static let yesterday = L10n.tr("Localizable", "filter.yesterday", fallback: "Yesterday")
  }
  public enum General {
    /// Activity
    public static let activity = L10n.tr("Localizable", "general.activity", fallback: "Activity")
    /// Back
    public static let back = L10n.tr("Localizable", "general.back", fallback: "Back")
    /// Cancel
    public static let cancel = L10n.tr("Localizable", "general.cancel", fallback: "Cancel")
    /// Close
    public static let close = L10n.tr("Localizable", "general.close", fallback: "Close")
    /// Confirm
    public static let confirm = L10n.tr("Localizable", "general.confirm", fallback: "Confirm")
    /// Copied %@
    public static func copiedAddress(_ p1: Any) -> String {
      return L10n.tr("Localizable", "general.copiedAddress", String(describing: p1), fallback: "Copied %@")
    }
    /// Copied amount
    public static let copiedAmount = L10n.tr("Localizable", "general.copiedAmount", fallback: "Copied amount")
    /// Copied to the clipboard!
    public static let copiedToTheClipboard = L10n.tr("Localizable", "general.copiedToTheClipboard", fallback: "Copied to the clipboard!")
    /// Delete
    public static let delete = L10n.tr("Localizable", "general.delete", fallback: "Delete")
    /// Done
    public static let done = L10n.tr("Localizable", "general.done", fallback: "Done")
    /// Typical Fee < %@
    public static func fee(_ p1: Any) -> String {
      return L10n.tr("Localizable", "general.fee", String(describing: p1), fallback: "Typical Fee < %@")
    }
    /// < %@
    public static func feeShort(_ p1: Any) -> String {
      return L10n.tr("Localizable", "general.feeShort", String(describing: p1), fallback: "< %@")
    }
    /// Hide
    public static let hide = L10n.tr("Localizable", "general.hide", fallback: "Hide")
    /// 
    public static let hideBalancesLeast = L10n.tr("Localizable", "general.hideBalancesLeast", fallback: "")
    /// -----
    public static let hideBalancesMost = L10n.tr("Localizable", "general.hideBalancesMost", fallback: "-----")
    /// -----
    public static let hideBalancesMostStandalone = L10n.tr("Localizable", "general.hideBalancesMostStandalone", fallback: "-----")
    /// Less
    public static let less = L10n.tr("Localizable", "general.less", fallback: "Less")
    /// Loading
    public static let loading = L10n.tr("Localizable", "general.loading", fallback: "Loading")
    /// Max
    public static let max = L10n.tr("Localizable", "general.max", fallback: "Max")
    /// More
    public static let more = L10n.tr("Localizable", "general.more", fallback: "More")
    /// Next
    public static let next = L10n.tr("Localizable", "general.next", fallback: "Next")
    /// No
    public static let no = L10n.tr("Localizable", "general.no", fallback: "No")
    /// Ok
    public static let ok = L10n.tr("Localizable", "general.ok", fallback: "Ok")
    /// Request
    public static let request = L10n.tr("Localizable", "general.request", fallback: "Request")
    /// Save
    public static let save = L10n.tr("Localizable", "general.save", fallback: "Save")
    /// Send
    public static let send = L10n.tr("Localizable", "general.send", fallback: "Send")
    /// Share
    public static let share = L10n.tr("Localizable", "general.share", fallback: "Share")
    /// Show
    public static let show = L10n.tr("Localizable", "general.show", fallback: "Show")
    /// Success
    public static let success = L10n.tr("Localizable", "general.success", fallback: "Success")
    /// Tap to copy
    public static let tapToCopy = L10n.tr("Localizable", "general.tapToCopy", fallback: "Tap to copy")
    /// Unknown
    public static let unknown = L10n.tr("Localizable", "general.unknown", fallback: "Unknown")
    /// Yes
    public static let yes = L10n.tr("Localizable", "general.yes", fallback: "Yes")
    public enum Alert {
      /// Heads up
      public static let caution = L10n.tr("Localizable", "general.alert.caution", fallback: "Heads up")
      /// Continue
      public static let `continue` = L10n.tr("Localizable", "general.alert.continue", fallback: "Continue")
      /// Ignore
      public static let ignore = L10n.tr("Localizable", "general.alert.ignore", fallback: "Ignore")
      /// Warning
      public static let warning = L10n.tr("Localizable", "general.alert.warning", fallback: "Warning")
    }
  }
  public enum Home {
    /// Upgrading databases…
    public static let migratingDatabases = L10n.tr("Localizable", "home.migratingDatabases", fallback: "Upgrading databases…")
  }
  public enum HomeScreen {
    /// Buy
    public static let buy = L10n.tr("Localizable", "homeScreen.buy", fallback: "Buy")
    /// More
    public static let more = L10n.tr("Localizable", "homeScreen.more", fallback: "More")
    /// More...
    public static let moreDotted = L10n.tr("Localizable", "homeScreen.moreDotted", fallback: "More...")
    /// Information you share with Zodl integration partners is subject to their privacy policies.
    public static let moreWarning = L10n.tr("Localizable", "homeScreen.moreWarning", fallback: "Information you share with Zodl integration partners is subject to their privacy policies.")
    /// Scan
    public static let scan = L10n.tr("Localizable", "homeScreen.scan", fallback: "Scan")
  }
  public enum ImportWallet {
    /// Enter secret
    /// recovery phrase
    public static let description = L10n.tr("Localizable", "importWallet.description", fallback: "Enter secret\nrecovery phrase")
    /// privacy dignity freedom ...
    public static let enterPlaceholder = L10n.tr("Localizable", "importWallet.enterPlaceholder", fallback: "privacy dignity freedom ...")
    /// Enter your 24-word seed phrase to restore the associated wallet.
    public static let message = L10n.tr("Localizable", "importWallet.message", fallback: "Enter your 24-word seed phrase to restore the associated wallet.")
    /// (optional)
    public static let optionalBirthday = L10n.tr("Localizable", "importWallet.optionalBirthday", fallback: "(optional)")
    public enum Alert {
      public enum Failed {
        /// Error: %@
        public static func message(_ p1: Any) -> String {
          return L10n.tr("Localizable", "importWallet.alert.failed.message", String(describing: p1), fallback: "Error: %@")
        }
        /// Failed to restore wallet
        public static let title = L10n.tr("Localizable", "importWallet.alert.failed.title", fallback: "Failed to restore wallet")
      }
      public enum Success {
        /// Your wallet has been successfully restored! During the initial sync, your funds cannot be spent or sent. Depending on the age of your wallet, it may take a few hours to fully sync.
        public static let message = L10n.tr("Localizable", "importWallet.alert.success.message", fallback: "Your wallet has been successfully restored! During the initial sync, your funds cannot be spent or sent. Depending on the age of your wallet, it may take a few hours to fully sync.")
      }
    }
    public enum Birthday {
      /// Wallet birthday height
      public static let title = L10n.tr("Localizable", "importWallet.birthday.title", fallback: "Wallet birthday height")
    }
    public enum Button {
      /// Restore
      public static let restoreWallet = L10n.tr("Localizable", "importWallet.button.restoreWallet", fallback: "Restore")
    }
    public enum Seed {
      /// VALID SEED PHRASE
      public static let valid = L10n.tr("Localizable", "importWallet.seed.valid", fallback: "VALID SEED PHRASE")
    }
  }
  public enum Integrations {
    /// Zodl integrations provide access to third party services. Features and information shared with them are outside of our control and subject to their privacy policies.
    public static let info = L10n.tr("Localizable", "integrations.info", fallback: "Zodl integrations provide access to third party services. Features and information shared with them are outside of our control and subject to their privacy policies.")
  }
  public enum Keystone {
    /// Confirm with Keystone
    public static let confirm = L10n.tr("Localizable", "keystone.confirm", fallback: "Confirm with Keystone")
    /// Pay with Keystone
    public static let confirmPay = L10n.tr("Localizable", "keystone.confirmPay", fallback: "Pay with Keystone")
    /// Swap with Keystone
    public static let confirmSwap = L10n.tr("Localizable", "keystone.confirmSwap", fallback: "Swap with Keystone")
    /// Connect Hardware Wallet
    public static let connect = L10n.tr("Localizable", "keystone.connect", fallback: "Connect Hardware Wallet")
    /// Scan Keystone wallet QR code
    public static let scanInfo = L10n.tr("Localizable", "keystone.scanInfo", fallback: "Scan Keystone wallet QR code")
    /// Scan Keystone QR code to sign the transaction
    public static let scanInfoTransaction = L10n.tr("Localizable", "keystone.scanInfoTransaction", fallback: "Scan Keystone QR code to sign the transaction")
    /// Switch from Keystone to Zodl to use Integrations.
    public static let settings = L10n.tr("Localizable", "keystone.settings", fallback: "Switch from Keystone to Zodl to use Integrations.")
    /// Keystone Wallet
    public static let wallet = L10n.tr("Localizable", "keystone.wallet", fallback: "Keystone Wallet")
    public enum AddHWWallet {
      /// Connect
      public static let connect = L10n.tr("Localizable", "keystone.addHWWallet.connect", fallback: "Connect")
      /// Select the wallet you'd like to connect to proceed. Once connected, you’ll be able to wirelessly sign transactions with your hardware wallet.
      public static let desc = L10n.tr("Localizable", "keystone.addHWWallet.desc", fallback: "Select the wallet you'd like to connect to proceed. Once connected, you’ll be able to wirelessly sign transactions with your hardware wallet.")
      /// Forget this device
      public static let forgetDevice = L10n.tr("Localizable", "keystone.addHWWallet.forgetDevice", fallback: "Forget this device")
      /// Instructions:
      public static let howTo = L10n.tr("Localizable", "keystone.addHWWallet.howTo", fallback: "Instructions:")
      /// Ready to Scan
      public static let readyToScan = L10n.tr("Localizable", "keystone.addHWWallet.readyToScan", fallback: "Ready to Scan")
      /// Scan your device’s QR code to connect.
      public static let scan = L10n.tr("Localizable", "keystone.addHWWallet.scan", fallback: "Scan your device’s QR code to connect.")
      /// Unlock your Keystone
      public static let step1 = L10n.tr("Localizable", "keystone.addHWWallet.step1", fallback: "Unlock your Keystone")
      /// Tap the menu icon
      public static let step2 = L10n.tr("Localizable", "keystone.addHWWallet.step2", fallback: "Tap the menu icon")
      /// Tap on Connect Software Wallet
      public static let step3 = L10n.tr("Localizable", "keystone.addHWWallet.step3", fallback: "Tap on Connect Software Wallet")
      /// Select Zashi app and scan QR code
      public static let step4 = L10n.tr("Localizable", "keystone.addHWWallet.step4", fallback: "Select Zashi app and scan QR code")
      /// Confirm Account to Access
      public static let title = L10n.tr("Localizable", "keystone.addHWWallet.title", fallback: "Confirm Account to Access")
      /// View Keystone tutorial
      public static let tutorial = L10n.tr("Localizable", "keystone.addHWWallet.tutorial", fallback: "View Keystone tutorial")
    }
    public enum Drawer {
      /// Wallets & Hardware
      public static let title = L10n.tr("Localizable", "keystone.drawer.title", fallback: "Wallets & Hardware")
      public enum Banner {
        /// Get 5%% off airgapped hardware wallet. Promo code "Zashi".
        public static let desc = L10n.tr("Localizable", "keystone.drawer.banner.desc", fallback: "Get 5%% off airgapped hardware wallet. Promo code \"Zashi\".")
        /// Keystone Hardware Wallet
        public static let title = L10n.tr("Localizable", "keystone.drawer.banner.title", fallback: "Keystone Hardware Wallet")
      }
    }
    public enum SignWith {
      /// After you have signed with Keystone, tap on the Get Signature button below.
      public static let desc = L10n.tr("Localizable", "keystone.signWith.desc", fallback: "After you have signed with Keystone, tap on the Get Signature button below.")
      /// Get Signature
      public static let getSignature = L10n.tr("Localizable", "keystone.signWith.getSignature", fallback: "Get Signature")
      /// Hardware
      public static let hardware = L10n.tr("Localizable", "keystone.signWith.hardware", fallback: "Hardware")
      /// Reject
      public static let reject = L10n.tr("Localizable", "keystone.signWith.reject", fallback: "Reject")
      /// Sign Transaction
      public static let signTransaction = L10n.tr("Localizable", "keystone.signWith.signTransaction", fallback: "Sign Transaction")
      /// Scan with your Keystone wallet
      public static let title = L10n.tr("Localizable", "keystone.signWith.title", fallback: "Scan with your Keystone wallet")
    }
  }
  public enum KeystoneTransactionReject {
    /// Go back
    public static let goBack = L10n.tr("Localizable", "keystoneTransactionReject.goBack", fallback: "Go back")
    /// Rejecting the signature will cancel the transaction, and you’ll need to start over if you want to proceed.
    public static let msg = L10n.tr("Localizable", "keystoneTransactionReject.msg", fallback: "Rejecting the signature will cancel the transaction, and you’ll need to start over if you want to proceed.")
    /// Reject Signature
    public static let rejectSig = L10n.tr("Localizable", "keystoneTransactionReject.rejectSig", fallback: "Reject Signature")
    /// Are you sure?
    public static let title = L10n.tr("Localizable", "keystoneTransactionReject.title", fallback: "Are you sure?")
  }
  public enum LocalAuthentication {
    /// The Following content requires authentication.
    public static let reason = L10n.tr("Localizable", "localAuthentication.reason", fallback: "The Following content requires authentication.")
  }
  public enum MessageEditor {
    /// Reply-to: Include my address in the memo
    public static let addUA = L10n.tr("Localizable", "messageEditor.addUA", fallback: "Reply-to: Include my address in the memo")
    /// 
    /// >>> reply-to: %@
    public static func addUAformat(_ p1: Any) -> String {
      return L10n.tr("Localizable", "messageEditor.addUAformat", String(describing: p1), fallback: "\n>>> reply-to: %@")
    }
    /// Your address is included in the memo
    public static let removeUA = L10n.tr("Localizable", "messageEditor.removeUA", fallback: "Your address is included in the memo")
  }
  public enum More {
    /// More Options
    public static let options = L10n.tr("Localizable", "more.options", fallback: "More Options")
  }
  public enum NewZodl {
    /// Same wallet, different name and logo.
    public static let allSame = L10n.tr("Localizable", "newZodl.allSame", fallback: "Same wallet, different name and logo.")
    /// We’ve rebranded, but everything you love stays the same. Zodl is the same app under a new banner.
    public static let desc = L10n.tr("Localizable", "newZodl.desc", fallback: "We’ve rebranded, but everything you love stays the same. Zodl is the same app under a new banner.")
    /// Go to Zodl
    public static let goTo = L10n.tr("Localizable", "newZodl.goTo", fallback: "Go to Zodl")
    /// Learn more
    public static let learnMore = L10n.tr("Localizable", "newZodl.learnMore", fallback: "Learn more")
    /// Everything works just like before:
    public static let likeBefore = L10n.tr("Localizable", "newZodl.likeBefore", fallback: "Everything works just like before:")
    /// Your funds and seed phrase remain secure and unchanged.
    public static let safeFunds = L10n.tr("Localizable", "newZodl.safeFunds", fallback: "Your funds and seed phrase remain secure and unchanged.")
    /// Same app
    public static let sameApp = L10n.tr("Localizable", "newZodl.sameApp", fallback: "Same app")
    /// Same mission
    public static let sameMission = L10n.tr("Localizable", "newZodl.sameMission", fallback: "Same mission")
    /// Same development team
    public static let sameTeam = L10n.tr("Localizable", "newZodl.sameTeam", fallback: "Same development team")
    /// Zashi is now Zodl
    public static let title = L10n.tr("Localizable", "newZodl.title", fallback: "Zashi is now Zodl")
  }
  public enum NotEnoughFreeSpace {
    /// %@ MB available. 
    public static func dataAvailable(_ p1: Any) -> String {
      return L10n.tr("Localizable", "notEnoughFreeSpace.dataAvailable", String(describing: p1), fallback: "%@ MB available. ")
    }
    /// Syncing will stay paused until more space is available.
    public static let messagePost = L10n.tr("Localizable", "notEnoughFreeSpace.messagePost", fallback: "Syncing will stay paused until more space is available.")
    /// Zodl requires %@ GB of space to synchronize the Zcash blockchain but there is only 
    public static func messagePre(_ p1: Any) -> String {
      return L10n.tr("Localizable", "notEnoughFreeSpace.messagePre", String(describing: p1), fallback: "Zodl requires %@ GB of space to synchronize the Zcash blockchain but there is only ")
    }
    /// ~%@ MB of additional space required to continue
    public static func requiredSpace(_ p1: Any) -> String {
      return L10n.tr("Localizable", "notEnoughFreeSpace.requiredSpace", String(describing: p1), fallback: "~%@ MB of additional space required to continue")
    }
    /// Not enough free space
    public static let title = L10n.tr("Localizable", "notEnoughFreeSpace.title", fallback: "Not enough free space")
  }
  public enum OsStatusError {
    /// Error code: %@
    public static func error(_ p1: Any) -> String {
      return L10n.tr("Localizable", "osStatusError.error", String(describing: p1), fallback: "Error code: %@")
    }
    /// Your funds are safe but something happened while we were trying to retrieve the Keychain data. Close the Zodl app, and give it a fresh launch, we will try again.
    public static let message = L10n.tr("Localizable", "osStatusError.message", fallback: "Your funds are safe but something happened while we were trying to retrieve the Keychain data. Close the Zodl app, and give it a fresh launch, we will try again.")
    /// It’s not you, it’s us.
    public static let title = L10n.tr("Localizable", "osStatusError.title", fallback: "It’s not you, it’s us.")
  }
  public enum Partners {
    /// https://pay.coinbase.com/buy/select-asset?appId=%@&addresses={"%@":["zcash"]}
    public static func coinbaseOnrampUrl(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "partners.coinbaseOnrampUrl", String(describing: p1), String(describing: p2), fallback: "https://pay.coinbase.com/buy/select-asset?appId=%@&addresses={\"%@\":[\"zcash\"]}")
    }
    public enum Flexa {
      /// We're sorry but something has failed. Please try again.
      public static let transactionFailedMessage = L10n.tr("Localizable", "partners.flexa.transactionFailedMessage", fallback: "We're sorry but something has failed. Please try again.")
      /// Transaction Failed
      public static let transactionFailedTitle = L10n.tr("Localizable", "partners.flexa.transactionFailedTitle", fallback: "Transaction Failed")
    }
  }
  public enum PlainOnboarding {
    /// Zcash-powered mobile wallet built for financial sovereignty.
    public static let title = L10n.tr("Localizable", "plainOnboarding.title", fallback: "Zcash-powered mobile wallet built for financial sovereignty.")
    public enum Button {
      /// Create new wallet
      public static let createNewWallet = L10n.tr("Localizable", "plainOnboarding.button.createNewWallet", fallback: "Create new wallet")
      /// Restore existing wallet
      public static let restoreWallet = L10n.tr("Localizable", "plainOnboarding.button.restoreWallet", fallback: "Restore existing wallet")
    }
  }
  public enum PrivateDataConsent {
    /// I agree to Zodl's Export Private Data Policies and Privacy Policy
    public static let confirmation = L10n.tr("Localizable", "privateDataConsent.confirmation", fallback: "I agree to Zodl's Export Private Data Policies and Privacy Policy")
    /// By clicking "I Agree" below, you give your consent to export all of your wallets’ private data such as the entire history of your wallet(s), including any connected hardware wallets. All private information, memos, amounts, and recipient addresses, even for your shielded activity will be exported.*
    public static let message1 = L10n.tr("Localizable", "privateDataConsent.message1", fallback: "By clicking \"I Agree\" below, you give your consent to export all of your wallets’ private data such as the entire history of your wallet(s), including any connected hardware wallets. All private information, memos, amounts, and recipient addresses, even for your shielded activity will be exported.*")
    /// The private data also gives the ability to see certain future actions you take with Zodl.
    public static let message2 = L10n.tr("Localizable", "privateDataConsent.message2", fallback: "The private data also gives the ability to see certain future actions you take with Zodl.")
    /// Sharing this private data is irrevocable - once you have shared this private data with someone, there is no way to revoke their access.
    public static let message3 = L10n.tr("Localizable", "privateDataConsent.message3", fallback: "Sharing this private data is irrevocable - once you have shared this private data with someone, there is no way to revoke their access.")
    /// *Note that this private data does not give them the ability to spend your funds, only the ability to see what you do with your funds.
    public static let message4 = L10n.tr("Localizable", "privateDataConsent.message4", fallback: "*Note that this private data does not give them the ability to spend your funds, only the ability to see what you do with your funds.")
    /// Data Export
    public static let screenTitle = L10n.tr("Localizable", "privateDataConsent.screenTitle", fallback: "Data Export")
    /// Consent for Exporting Private Data
    public static let title = L10n.tr("Localizable", "privateDataConsent.title", fallback: "Consent for Exporting Private Data")
  }
  public enum ProposalPartial {
    /// Copy transaction IDs
    public static let copyIds = L10n.tr("Localizable", "proposalPartial.copyIds", fallback: "Copy transaction IDs")
    /// Hi Zodl Team,
    public static let mailPart1 = L10n.tr("Localizable", "proposalPartial.mailPart1", fallback: "Hi Zodl Team,")
    /// While sending a transaction to a TEX address, I encountered an error state. I'm reaching out to get guidance on how to recover my funds.
    public static let mailPart2 = L10n.tr("Localizable", "proposalPartial.mailPart2", fallback: "While sending a transaction to a TEX address, I encountered an error state. I'm reaching out to get guidance on how to recover my funds.")
    /// Thank you.
    public static let mailPart3 = L10n.tr("Localizable", "proposalPartial.mailPart3", fallback: "Thank you.")
    /// TEX Transaction Error
    public static let mailSubject = L10n.tr("Localizable", "proposalPartial.mailSubject", fallback: "TEX Transaction Error")
    /// Send to this recipient required multiple transactions but only some of them succeeded and the rest failed. Your funds are safe but need to be recovered with assistance from our side.
    public static let message1 = L10n.tr("Localizable", "proposalPartial.message1", fallback: "Send to this recipient required multiple transactions but only some of them succeeded and the rest failed. Your funds are safe but need to be recovered with assistance from our side.")
    /// Please use the button below to contact us. it automatically prepares all the data we need in order to help you restore your funds.
    public static let message2 = L10n.tr("Localizable", "proposalPartial.message2", fallback: "Please use the button below to contact us. it automatically prepares all the data we need in order to help you restore your funds.")
    /// Send Failed
    public static let title = L10n.tr("Localizable", "proposalPartial.title", fallback: "Send Failed")
    /// Transaction Ids
    public static let transactionIds = L10n.tr("Localizable", "proposalPartial.transactionIds", fallback: "Transaction Ids")
    /// Transaction statuses:
    public static let transactionStatuses = L10n.tr("Localizable", "proposalPartial.transactionStatuses", fallback: "Transaction statuses:")
  }
  public enum Receive {
    /// Copy
    public static let copy = L10n.tr("Localizable", "receive.copy", fallback: "Copy")
    /// QR Code
    public static let qrCode = L10n.tr("Localizable", "receive.qrCode", fallback: "QR Code")
    /// Request
    public static let request = L10n.tr("Localizable", "receive.request", fallback: "Request")
    /// Sapling Address
    public static let sa = L10n.tr("Localizable", "receive.sa", fallback: "Sapling Address")
    /// Zcash Sapling Address
    public static let saplingAddress = L10n.tr("Localizable", "receive.saplingAddress", fallback: "Zcash Sapling Address")
    /// Transparent Address
    public static let ta = L10n.tr("Localizable", "receive.ta", fallback: "Transparent Address")
    /// Unified Address
    public static let ua = L10n.tr("Localizable", "receive.ua", fallback: "Unified Address")
    /// For privacy, always use shielded address.
    public static let warning = L10n.tr("Localizable", "receive.warning", fallback: "For privacy, always use shielded address.")
    public enum Error {
      /// could not extract sapling receiver from UA
      public static let cantExtractSaplingAddress = L10n.tr("Localizable", "receive.error.cantExtractSaplingAddress", fallback: "could not extract sapling receiver from UA")
      /// could not extract transparent receiver from UA
      public static let cantExtractTransparentAddress = L10n.tr("Localizable", "receive.error.cantExtractTransparentAddress", fallback: "could not extract transparent receiver from UA")
      /// could not extract UA
      public static let cantExtractUnifiedAddress = L10n.tr("Localizable", "receive.error.cantExtractUnifiedAddress", fallback: "could not extract UA")
    }
    public enum Help {
      public enum Shielded {
        /// Use this address to receive and store your ZEC privately. Transparent and shielded ZEC sent to this address will be received and stored as shielded ZEC.
        public static let desc1 = L10n.tr("Localizable", "receive.help.shielded.desc1", fallback: "Use this address to receive and store your ZEC privately. Transparent and shielded ZEC sent to this address will be received and stored as shielded ZEC.")
        /// A new Zcash Shielded Address is generated each time you open the Receive screen.
        public static let desc2 = L10n.tr("Localizable", "receive.help.shielded.desc2", fallback: "A new Zcash Shielded Address is generated each time you open the Receive screen.")
        /// All transactions sent to your different rotating Shielded Addresses will remain part of one wallet balance under the same seed phrase.
        public static let desc3 = L10n.tr("Localizable", "receive.help.shielded.desc3", fallback: "All transactions sent to your different rotating Shielded Addresses will remain part of one wallet balance under the same seed phrase.")
        /// While we recommend using a new address every time, each unique address can be reused.
        public static let desc4 = L10n.tr("Localizable", "receive.help.shielded.desc4", fallback: "While we recommend using a new address every time, each unique address can be reused.")
        /// Zcash Shielded Address (Rotating)
        public static let title = L10n.tr("Localizable", "receive.help.shielded.title", fallback: "Zcash Shielded Address (Rotating)")
      }
      public enum Transparent {
        /// This addresses type works just like Bitcoin addresses and offers NO PRIVACY. The details of transactions sent to this address will be public and visible on the blockchain.
        public static let desc1 = L10n.tr("Localizable", "receive.help.transparent.desc1", fallback: "This addresses type works just like Bitcoin addresses and offers NO PRIVACY. The details of transactions sent to this address will be public and visible on the blockchain.")
        /// We don't recommend using this address type unless the wallet or exchange from which ZEC is being sent doesn’t support sending funds to shielded Zcash addresses.
        public static let desc2 = L10n.tr("Localizable", "receive.help.transparent.desc2", fallback: "We don't recommend using this address type unless the wallet or exchange from which ZEC is being sent doesn’t support sending funds to shielded Zcash addresses.")
        /// To protect your privacy, Zodl will guide you to shield any transparent ZEC you receive with just one click.
        public static let desc3 = L10n.tr("Localizable", "receive.help.transparent.desc3", fallback: "To protect your privacy, Zodl will guide you to shield any transparent ZEC you receive with just one click.")
        /// You won't be able to spend your transparent ZEC until you shield it.
        public static let desc4 = L10n.tr("Localizable", "receive.help.transparent.desc4", fallback: "You won't be able to spend your transparent ZEC until you shield it.")
        /// Zcash Transparent Address (Static)
        public static let title = L10n.tr("Localizable", "receive.help.transparent.title", fallback: "Zcash Transparent Address (Static)")
      }
    }
    public enum Ua {
      /// Rotates every time you use it
      public static let rotateInfo = L10n.tr("Localizable", "receive.ua.rotateInfo", fallback: "Rotates every time you use it")
    }
  }
  public enum RecoverFunds {
    /// Scan address
    public static let btn = L10n.tr("Localizable", "recoverFunds.btn", fallback: "Scan address")
    /// Transparent Address
    public static let fieldTitle = L10n.tr("Localizable", "recoverFunds.fieldTitle", fallback: "Transparent Address")
    /// If you confirm, Zodl will scan the transparent address you provide and discover its funds. This may take a few minutes.
    public static let msg = L10n.tr("Localizable", "recoverFunds.msg", fallback: "If you confirm, Zodl will scan the transparent address you provide and discover its funds. This may take a few minutes.")
    /// Enter or paste...
    public static let placeholder = L10n.tr("Localizable", "recoverFunds.placeholder", fallback: "Enter or paste...")
    /// Discover Funds
    public static let title = L10n.tr("Localizable", "recoverFunds.title", fallback: "Discover Funds")
    /// This operation requires Tor Protection. Please enable it in the Advanced Settings. 
    public static let tor = L10n.tr("Localizable", "recoverFunds.tor", fallback: "This operation requires Tor Protection. Please enable it in the Advanced Settings. ")
  }
  public enum RecoveryPhraseDisplay {
    /// Wallet Birthday Height
    public static let birthdayTitle = L10n.tr("Localizable", "recoveryPhraseDisplay.birthdayTitle", fallback: "Wallet Birthday Height")
    /// These words are the only way to recover your funds! Make sure to save them in the correct order.
    public static let description = L10n.tr("Localizable", "recoveryPhraseDisplay.description", fallback: "These words are the only way to recover your funds! Make sure to save them in the correct order.")
    /// Hide security details
    public static let hide = L10n.tr("Localizable", "recoveryPhraseDisplay.hide", fallback: "Hide security details")
    /// The keys are missing. No backup phrase is stored in the keychain.
    public static let noWords = L10n.tr("Localizable", "recoveryPhraseDisplay.noWords", fallback: "The keys are missing. No backup phrase is stored in the keychain.")
    /// Keep this phrase securely hidden. Don’t take screenshots of it or store it on your phone!
    public static let proceedWarning = L10n.tr("Localizable", "recoveryPhraseDisplay.proceedWarning", fallback: "Keep this phrase securely hidden. Don’t take screenshots of it or store it on your phone!")
    /// Reveal security details
    public static let reveal = L10n.tr("Localizable", "recoveryPhraseDisplay.reveal", fallback: "Reveal security details")
    /// Wallet Backup
    public static let screenTitle = L10n.tr("Localizable", "recoveryPhraseDisplay.screenTitle", fallback: "Wallet Backup")
    /// Secret Recovery Phrase
    public static let title = L10n.tr("Localizable", "recoveryPhraseDisplay.title", fallback: "Secret Recovery Phrase")
    /// Your secret recovery phrase is a unique set of 24 words, appearing in a precise order. It protects access to your funds.
    public static let warningInfo = L10n.tr("Localizable", "recoveryPhraseDisplay.warningInfo", fallback: "Your secret recovery phrase is a unique set of 24 words, appearing in a precise order. It protects access to your funds.")
    /// Your Secret Recovery Phrase
    public static let warningTitle = L10n.tr("Localizable", "recoveryPhraseDisplay.warningTitle", fallback: "Your Secret Recovery Phrase")
    public enum Alert {
      public enum Failed {
        /// Attempt to load the stored wallet from the keychain failed. Error: %@
        public static func message(_ p1: Any) -> String {
          return L10n.tr("Localizable", "recoveryPhraseDisplay.alert.failed.message", String(describing: p1), fallback: "Attempt to load the stored wallet from the keychain failed. Error: %@")
        }
        /// Failed to load stored wallet
        public static let title = L10n.tr("Localizable", "recoveryPhraseDisplay.alert.failed.title", fallback: "Failed to load stored wallet")
      }
    }
    public enum Button {
      /// Remind me later
      public static let remindMeLater = L10n.tr("Localizable", "recoveryPhraseDisplay.button.remindMeLater", fallback: "Remind me later")
      /// I've saved it
      public static let wroteItDown = L10n.tr("Localizable", "recoveryPhraseDisplay.button.wroteItDown", fallback: "I've saved it")
    }
    public enum WarningControl {
      /// Use it to access your funds from other devices and Zcash wallets.
      public static let info = L10n.tr("Localizable", "recoveryPhraseDisplay.warningControl.info", fallback: "Use it to access your funds from other devices and Zcash wallets.")
      /// Control your wallet
      public static let title = L10n.tr("Localizable", "recoveryPhraseDisplay.warningControl.title", fallback: "Control your wallet")
    }
    public enum WarningHeight {
      /// The block height at which your wallet was created can significantly speed up the wallet recovery process.
      public static let info = L10n.tr("Localizable", "recoveryPhraseDisplay.warningHeight.info", fallback: "The block height at which your wallet was created can significantly speed up the wallet recovery process.")
      /// Wallet birthday height
      public static let title = L10n.tr("Localizable", "recoveryPhraseDisplay.warningHeight.title", fallback: "Wallet birthday height")
    }
    public enum WarningKeep {
      /// Don't share it with anyone! It can be used to gain full control of your funds.
      public static let info = L10n.tr("Localizable", "recoveryPhraseDisplay.warningKeep.info", fallback: "Don't share it with anyone! It can be used to gain full control of your funds.")
      /// Keep it private
      public static let title = L10n.tr("Localizable", "recoveryPhraseDisplay.warningKeep.title", fallback: "Keep it private")
    }
    public enum WarningStore {
      /// We don’t have access to it and will never ask for it. If you lose it, it cannot be recovered.
      public static let info = L10n.tr("Localizable", "recoveryPhraseDisplay.warningStore.info", fallback: "We don’t have access to it and will never ask for it. If you lose it, it cannot be recovered.")
      /// Store it securely
      public static let title = L10n.tr("Localizable", "recoveryPhraseDisplay.warningStore.title", fallback: "Store it securely")
    }
  }
  public enum RequestZec {
    /// Payment Request
    public static let title = L10n.tr("Localizable", "requestZec.title", fallback: "Payment Request")
    /// What’s this for?
    public static let whatFor = L10n.tr("Localizable", "requestZec.whatFor", fallback: "What’s this for?")
    public enum Summary {
      /// Hi, I have generated a ZEC payment request for you using the Zodl app!
      public static let shareDesc = L10n.tr("Localizable", "requestZec.summary.shareDesc", fallback: "Hi, I have generated a ZEC payment request for you using the Zodl app!")
      /// (download link: https://apps.apple.com/app/zashi-zcash-wallet/id1672392439)
      public static let shareMsg = L10n.tr("Localizable", "requestZec.summary.shareMsg", fallback: "(download link: https://apps.apple.com/app/zashi-zcash-wallet/id1672392439)")
      /// Share QR Code
      public static let shareQR = L10n.tr("Localizable", "requestZec.summary.shareQR", fallback: "Share QR Code")
      /// Request ZEC
      public static let shareTitle = L10n.tr("Localizable", "requestZec.summary.shareTitle", fallback: "Request ZEC")
    }
  }
  public enum RestoreInfo {
    /// Keep screen on while restoring
    public static let checkbox = L10n.tr("Localizable", "restoreInfo.checkbox", fallback: "Keep screen on while restoring")
    /// Got it!
    public static let gotIt = L10n.tr("Localizable", "restoreInfo.gotIt", fallback: "Got it!")
    /// Note: 
    public static let note = L10n.tr("Localizable", "restoreInfo.note", fallback: "Note: ")
    /// Your funds cannot be spent with Zodl until your wallet is fully restored.
    public static let noteInfo = L10n.tr("Localizable", "restoreInfo.noteInfo", fallback: "Your funds cannot be spent with Zodl until your wallet is fully restored.")
    /// Your wallet is being restored.
    public static let subTitle = L10n.tr("Localizable", "restoreInfo.subTitle", fallback: "Your wallet is being restored.")
    /// Keep the Zodl app open on an active phone screen.
    public static let tip1 = L10n.tr("Localizable", "restoreInfo.tip1", fallback: "Keep the Zodl app open on an active phone screen.")
    /// To prevent your phone screen from going dark, turn off power-saving mode and keep your phone plugged in.
    public static let tip2 = L10n.tr("Localizable", "restoreInfo.tip2", fallback: "To prevent your phone screen from going dark, turn off power-saving mode and keep your phone plugged in.")
    /// Zodl is scanning the blockchain to retrieve your transactions. Older wallets can take hours to restore. Follow these steps to prevent interruption:
    public static let tips = L10n.tr("Localizable", "restoreInfo.tips", fallback: "Zodl is scanning the blockchain to retrieve your transactions. Older wallets can take hours to restore. Follow these steps to prevent interruption:")
    /// Keep Zodl open!
    public static let title = L10n.tr("Localizable", "restoreInfo.title", fallback: "Keep Zodl open!")
  }
  public enum RestoreWallet {
    /// If you’re not sure, choose an earlier date.
    public static let dateTip = L10n.tr("Localizable", "restoreWallet.dateTip", fallback: "If you’re not sure, choose an earlier date.")
    /// Please type in your 24-word secret recovery phrase in the correct order.
    public static let info = L10n.tr("Localizable", "restoreWallet.info", fallback: "Please type in your 24-word secret recovery phrase in the correct order.")
    /// Secret Recovery Phrase
    public static let title = L10n.tr("Localizable", "restoreWallet.title", fallback: "Secret Recovery Phrase")
    public enum Birthday {
      /// Estimate my block height
      public static let estimate = L10n.tr("Localizable", "restoreWallet.birthday.estimate", fallback: "Estimate my block height")
      /// Wallet Birthday Height is the point in time when your wallet was created.
      public static let fieldInfo = L10n.tr("Localizable", "restoreWallet.birthday.fieldInfo", fallback: "Wallet Birthday Height is the point in time when your wallet was created.")
      /// Entering your Wallet Birthday Height helps speed up the restore process.
      public static let info = L10n.tr("Localizable", "restoreWallet.birthday.info", fallback: "Entering your Wallet Birthday Height helps speed up the restore process.")
      /// Enter number
      public static let placeholder = L10n.tr("Localizable", "restoreWallet.birthday.placeholder", fallback: "Enter number")
      /// Block Height
      public static let title = L10n.tr("Localizable", "restoreWallet.birthday.title", fallback: "Block Height")
      public enum EstimateDate {
        /// Entering the block height at which your wallet was created reduces the number of blocks that need to be scanned to recover your wallet.
        public static let info = L10n.tr("Localizable", "restoreWallet.birthday.estimateDate.info", fallback: "Entering the block height at which your wallet was created reduces the number of blocks that need to be scanned to recover your wallet.")
        /// First Wallet Transaction
        public static let title = L10n.tr("Localizable", "restoreWallet.birthday.estimateDate.title", fallback: "First Wallet Transaction")
        /// If you’re not sure, choose an earlier date.
        public static let warning = L10n.tr("Localizable", "restoreWallet.birthday.estimateDate.warning", fallback: "If you’re not sure, choose an earlier date.")
      }
      public enum Estimated {
        /// Zodl will scan and recover all transactions made after the following block number.
        public static let info = L10n.tr("Localizable", "restoreWallet.birthday.estimated.info", fallback: "Zodl will scan and recover all transactions made after the following block number.")
        /// Estimated Block Height
        public static let title = L10n.tr("Localizable", "restoreWallet.birthday.estimated.title", fallback: "Estimated Block Height")
      }
    }
    public enum Help {
      /// ^[The Wallet Birthday Height](style: 'boldPrimary') is the block height (block # in the blockchain) at which your wallet was created. If you ever lose access to your Zodl app and need to recover your funds, providing the block height along with your recovery phrase can significantly speed up the process.
      public static let birthday = L10n.tr("Localizable", "restoreWallet.help.birthday", fallback: "^[The Wallet Birthday Height](style: 'boldPrimary') is the block height (block # in the blockchain) at which your wallet was created. If you ever lose access to your Zodl app and need to recover your funds, providing the block height along with your recovery phrase can significantly speed up the process.")
      /// ^[The Secret Recovery Phrase](style: 'boldPrimary') is a unique set of 24 words, appearing in a precise order. It can be used to gain full control of your funds from any device via any Zcash wallet app. Think of it as the master key to your wallet. It is stored in Zodl’s Advanced Settings.
      public static let phrase = L10n.tr("Localizable", "restoreWallet.help.phrase", fallback: "^[The Secret Recovery Phrase](style: 'boldPrimary') is a unique set of 24 words, appearing in a precise order. It can be used to gain full control of your funds from any device via any Zcash wallet app. Think of it as the master key to your wallet. It is stored in Zodl’s Advanced Settings.")
      /// Need to know more?
      public static let title = L10n.tr("Localizable", "restoreWallet.help.title", fallback: "Need to know more?")
    }
  }
  public enum Root {
    public enum Debug {
      /// Startup
      public static let navigationTitle = L10n.tr("Localizable", "root.debug.navigationTitle", fallback: "Startup")
      /// Support options
      public static let title = L10n.tr("Localizable", "root.debug.title", fallback: "Support options")
      public enum Alert {
        public enum Rewind {
          public enum CantStartSync {
            /// Error: %@
            public static func message(_ p1: Any) -> String {
              return L10n.tr("Localizable", "root.debug.alert.rewind.cantStartSync.message", String(describing: p1), fallback: "Error: %@")
            }
            /// Can't start sync process after rewind
            public static let title = L10n.tr("Localizable", "root.debug.alert.rewind.cantStartSync.title", fallback: "Can't start sync process after rewind")
          }
          public enum Failed {
            /// Error: %@
            public static func message(_ p1: Any) -> String {
              return L10n.tr("Localizable", "root.debug.alert.rewind.failed.message", String(describing: p1), fallback: "Error: %@")
            }
            /// Rewind failed
            public static let title = L10n.tr("Localizable", "root.debug.alert.rewind.failed.title", fallback: "Rewind failed")
          }
        }
      }
      public enum Dialog {
        public enum Rescan {
          /// Select the rescan you want
          public static let message = L10n.tr("Localizable", "root.debug.dialog.rescan.message", fallback: "Select the rescan you want")
          /// Rescan
          public static let title = L10n.tr("Localizable", "root.debug.dialog.rescan.title", fallback: "Rescan")
          public enum Option {
            /// Full rescan
            public static let full = L10n.tr("Localizable", "root.debug.dialog.rescan.option.full", fallback: "Full rescan")
            /// Quick rescan
            public static let quick = L10n.tr("Localizable", "root.debug.dialog.rescan.option.quick", fallback: "Quick rescan")
          }
        }
      }
      public enum Option {
        /// Rate the App
        public static let appReview = L10n.tr("Localizable", "root.debug.option.appReview", fallback: "Rate the App")
        /// Copy seed to pasteboard
        public static let copySeed = L10n.tr("Localizable", "root.debug.option.copySeed", fallback: "Copy seed to pasteboard")
        /// Export Logs
        public static let exportLogs = L10n.tr("Localizable", "root.debug.option.exportLogs", fallback: "Export Logs")
        /// [Be careful] Nuke Wallet
        public static let nukeWallet = L10n.tr("Localizable", "root.debug.option.nukeWallet", fallback: "[Be careful] Nuke Wallet")
        /// Rescan Blockchain
        public static let rescanBlockchain = L10n.tr("Localizable", "root.debug.option.rescanBlockchain", fallback: "Rescan Blockchain")
      }
    }
    public enum Destination {
      public enum Alert {
        public enum FailedToProcessDeeplink {
          /// Deeplink: (%@))
          /// Error: (%@) (code: %@)
          public static func message(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
            return L10n.tr("Localizable", "root.destination.alert.failedToProcessDeeplink.message", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "Deeplink: (%@))\nError: (%@) (code: %@)")
          }
          /// Failed to process deeplink.
          public static let title = L10n.tr("Localizable", "root.destination.alert.failedToProcessDeeplink.title", fallback: "Failed to process deeplink.")
        }
      }
    }
    public enum ExistingWallet {
      /// We identified a Zodl database backup on this device. If you create a new wallet, you will lose access to this database backup and if you try to restore later, some information may be lost.
      public static let message = L10n.tr("Localizable", "root.existingWallet.Message", fallback: "We identified a Zodl database backup on this device. If you create a new wallet, you will lose access to this database backup and if you try to restore later, some information may be lost.")
      /// Restore
      public static let restore = L10n.tr("Localizable", "root.existingWallet.restore", fallback: "Restore")
    }
    public enum Initialization {
      public enum Alert {
        public enum CantCreateNewWallet {
          /// Can't create new wallet. Error: %@
          public static func message(_ p1: Any) -> String {
            return L10n.tr("Localizable", "root.initialization.alert.cantCreateNewWallet.message", String(describing: p1), fallback: "Can't create new wallet. Error: %@")
          }
        }
        public enum CantLoadSeedPhrase {
          /// Can't load seed phrase from local storage.
          public static let message = L10n.tr("Localizable", "root.initialization.alert.cantLoadSeedPhrase.message", fallback: "Can't load seed phrase from local storage.")
        }
        public enum CantStoreThatUserPassedPhraseBackupTest {
          /// Can't store information that user passed phrase backup test. Error: %@
          public static func message(_ p1: Any) -> String {
            return L10n.tr("Localizable", "root.initialization.alert.cantStoreThatUserPassedPhraseBackupTest.message", String(describing: p1), fallback: "Can't store information that user passed phrase backup test. Error: %@")
          }
        }
        public enum Error {
          /// Error: %@
          public static func message(_ p1: Any) -> String {
            return L10n.tr("Localizable", "root.initialization.alert.error.message", String(describing: p1), fallback: "Error: %@")
          }
        }
        public enum Failed {
          /// Wallet initialisation failed.
          public static let title = L10n.tr("Localizable", "root.initialization.alert.failed.title", fallback: "Wallet initialisation failed.")
        }
        public enum SdkInitFailed {
          /// Failed to initialize the SDK
          public static let title = L10n.tr("Localizable", "root.initialization.alert.sdkInitFailed.title", fallback: "Failed to initialize the SDK")
        }
        public enum WalletStateFailed {
          /// App initialisation state: %@.
          public static func message(_ p1: Any) -> String {
            return L10n.tr("Localizable", "root.initialization.alert.walletStateFailed.message", String(describing: p1), fallback: "App initialisation state: %@.")
          }
        }
        public enum Wipe {
          /// Are you sure?
          public static let message = L10n.tr("Localizable", "root.initialization.alert.wipe.message", fallback: "Are you sure?")
          /// Wipe of the wallet
          public static let title = L10n.tr("Localizable", "root.initialization.alert.wipe.title", fallback: "Wipe of the wallet")
        }
        public enum WipeFailed {
          /// Wallet deletion only partially succeeded. Please retry to finish the resetting process.
          public static let message = L10n.tr("Localizable", "root.initialization.alert.wipeFailed.message", fallback: "Wallet deletion only partially succeeded. Please retry to finish the resetting process.")
          /// Wallet deletion failed.
          public static let title = L10n.tr("Localizable", "root.initialization.alert.wipeFailed.title", fallback: "Wallet deletion failed.")
        }
      }
    }
    public enum SeedPhrase {
      public enum DifferentSeed {
        /// This recovery phrase doesn't match the Zodl database backup saved on this device. If you proceed, you will lose access to this database backup and if you try to restore later, some information may be lost.
        public static let message = L10n.tr("Localizable", "root.seedPhrase.differentSeed.message", fallback: "This recovery phrase doesn't match the Zodl database backup saved on this device. If you proceed, you will lose access to this database backup and if you try to restore later, some information may be lost.")
        /// Try Again
        public static let tryAgain = L10n.tr("Localizable", "root.seedPhrase.differentSeed.tryAgain", fallback: "Try Again")
      }
    }
    public enum ServiceUnavailable {
      /// Your current server is experiencing difficulties. Check your device connection, and/or navigate to Advanced Settings to choose a different server.
      public static let message = L10n.tr("Localizable", "root.serviceUnavailable.Message", fallback: "Your current server is experiencing difficulties. Check your device connection, and/or navigate to Advanced Settings to choose a different server.")
      /// Switch server
      public static let switchServer = L10n.tr("Localizable", "root.serviceUnavailable.switchServer", fallback: "Switch server")
    }
  }
  public enum Scan {
    /// The camera is not authorized. Please go to the system settings of Zodl and turn it on.
    public static let cameraSettings = L10n.tr("Localizable", "scan.cameraSettings", fallback: "The camera is not authorized. Please go to the system settings of Zodl and turn it on.")
    /// This image doesn't hold a valid Zcash address.
    public static let invalidImage = L10n.tr("Localizable", "scan.invalidImage", fallback: "This image doesn't hold a valid Zcash address.")
    /// This QR code doesn't hold a valid Zcash address.
    public static let invalidQR = L10n.tr("Localizable", "scan.invalidQR", fallback: "This QR code doesn't hold a valid Zcash address.")
    /// Open settings
    public static let openSettings = L10n.tr("Localizable", "scan.openSettings", fallback: "Open settings")
    /// This image holds several valid Zcash addresses.
    public static let severalCodesFound = L10n.tr("Localizable", "scan.severalCodesFound", fallback: "This image holds several valid Zcash addresses.")
  }
  public enum Send {
    /// Add contact by tapping on Address Book icon.
    public static let addressNotInBook = L10n.tr("Localizable", "send.addressNotInBook", fallback: "Add contact by tapping on Address Book icon.")
    /// Zcash Address
    public static let addressPlaceholder = L10n.tr("Localizable", "send.addressPlaceholder", fallback: "Zcash Address")
    /// Amount
    public static let amount = L10n.tr("Localizable", "send.amount", fallback: "Amount")
    /// Total Amount
    public static let amountSummary = L10n.tr("Localizable", "send.amountSummary", fallback: "Total Amount")
    /// Confirmation
    public static let confirmationTitle = L10n.tr("Localizable", "send.confirmationTitle", fallback: "Confirmation")
    /// USD
    public static let currencyPlaceholder = L10n.tr("Localizable", "send.currencyPlaceholder", fallback: "USD")
    /// Unable to send
    public static let failure = L10n.tr("Localizable", "send.failure", fallback: "Unable to send")
    /// There was an error attempting to send coins. Try it again, please.
    public static let failureInfo = L10n.tr("Localizable", "send.failureInfo", fallback: "There was an error attempting to send coins. Try it again, please.")
    /// Unable to shield
    public static let failureShielding = L10n.tr("Localizable", "send.failureShielding", fallback: "Unable to shield")
    /// There was an error attempting to shield your coins. Try it again, please.
    public static let failureShieldingInfo = L10n.tr("Localizable", "send.failureShieldingInfo", fallback: "There was an error attempting to shield your coins. Try it again, please.")
    /// Fee
    public static let feeSummary = L10n.tr("Localizable", "send.feeSummary", fallback: "Fee")
    /// Cancel
    public static let goBack = L10n.tr("Localizable", "send.goBack", fallback: "Cancel")
    /// Write encrypted message here...
    public static let memoPlaceholder = L10n.tr("Localizable", "send.memoPlaceholder", fallback: "Write encrypted message here...")
    /// Message
    public static let message = L10n.tr("Localizable", "send.message", fallback: "Message")
    /// Your transaction is being processed.
    public static let pendingInfo = L10n.tr("Localizable", "send.pendingInfo", fallback: "Your transaction is being processed.")
    /// Your shielding transaction is being processed.
    public static let pendingShieldingInfo = L10n.tr("Localizable", "send.pendingShieldingInfo", fallback: "Your shielding transaction is being processed.")
    /// Shielding Pending
    public static let pendingShieldingTitle = L10n.tr("Localizable", "send.pendingShieldingTitle", fallback: "Shielding Pending")
    /// Transaction Pending
    public static let pendingTitle = L10n.tr("Localizable", "send.pendingTitle", fallback: "Transaction Pending")
    /// Report
    public static let report = L10n.tr("Localizable", "send.report", fallback: "Report")
    /// Connection Issue
    public static let resubmission = L10n.tr("Localizable", "send.resubmission", fallback: "Connection Issue")
    /// Zodl encountered connection issues when submitting the transaction. It will retry in the next few minutes.
    public static let resubmissionInfo = L10n.tr("Localizable", "send.resubmissionInfo", fallback: "Zodl encountered connection issues when submitting the transaction. It will retry in the next few minutes.")
    /// Review
    public static let review = L10n.tr("Localizable", "send.review", fallback: "Review")
    /// Sending...
    public static let sending = L10n.tr("Localizable", "send.sending", fallback: "Sending...")
    /// Your coins are being sent to
    public static let sendingInfo = L10n.tr("Localizable", "send.sendingInfo", fallback: "Your coins are being sent to")
    /// Shielding
    public static let shielding = L10n.tr("Localizable", "send.shielding", fallback: "Shielding")
    /// Your coins are getting shielded
    public static let shieldingInfo = L10n.tr("Localizable", "send.shieldingInfo", fallback: "Your coins are getting shielded")
    /// Sent!
    public static let success = L10n.tr("Localizable", "send.success", fallback: "Sent!")
    /// Your coins were successfully sent to
    public static let successInfo = L10n.tr("Localizable", "send.successInfo", fallback: "Your coins were successfully sent to")
    /// Shielded!
    public static let successShielding = L10n.tr("Localizable", "send.successShielding", fallback: "Shielded!")
    /// Your coins have been successfully shielded
    public static let successShieldingInfo = L10n.tr("Localizable", "send.successShieldingInfo", fallback: "Your coins have been successfully shielded")
    /// Send to
    public static let to = L10n.tr("Localizable", "send.to", fallback: "Send to")
    /// Send to
    public static let toSummary = L10n.tr("Localizable", "send.toSummary", fallback: "Send to")
    /// View Transaction
    public static let viewTransaction = L10n.tr("Localizable", "send.viewTransaction", fallback: "View Transaction")
    public enum Alert {
      public enum Failure {
        /// Error: %@
        public static func message(_ p1: Any) -> String {
          return L10n.tr("Localizable", "send.alert.failure.message", String(describing: p1), fallback: "Error: %@")
        }
        /// Failed to send funds
        public static let title = L10n.tr("Localizable", "send.alert.failure.title", fallback: "Failed to send funds")
      }
    }
    public enum Error {
      /// Insufficient funds
      public static let insufficientFunds = L10n.tr("Localizable", "send.error.insufficientFunds", fallback: "Insufficient funds")
      /// Invalid address
      public static let invalidAddress = L10n.tr("Localizable", "send.error.invalidAddress", fallback: "Invalid address")
      /// Invalid amount
      public static let invalidAmount = L10n.tr("Localizable", "send.error.invalidAmount", fallback: "Invalid amount")
    }
    public enum Info {
      /// Transparent transactions can’t have memos
      public static let memo = L10n.tr("Localizable", "send.info.memo", fallback: "Transparent transactions can’t have memos")
    }
    public enum RequestPayment {
      /// For:
      public static let `for` = L10n.tr("Localizable", "send.requestPayment.for", fallback: "For:")
      /// Requested By
      public static let requestedBy = L10n.tr("Localizable", "send.requestPayment.requestedBy", fallback: "Requested By")
      /// Payment Request
      public static let title = L10n.tr("Localizable", "send.requestPayment.title", fallback: "Payment Request")
      /// Total
      public static let total = L10n.tr("Localizable", "send.requestPayment.total", fallback: "Total")
    }
  }
  public enum SendFeedback {
    /// Please let us know about any problems you have had, or features you want to see in the future.
    public static let desc = L10n.tr("Localizable", "sendFeedback.desc", fallback: "Please let us know about any problems you have had, or features you want to see in the future.")
    /// I would like to ask about...
    public static let hcwhPlaceholder = L10n.tr("Localizable", "sendFeedback.hcwhPlaceholder", fallback: "I would like to ask about...")
    /// How can we help you?
    public static let howCanWeHelp = L10n.tr("Localizable", "sendFeedback.howCanWeHelp", fallback: "How can we help you?")
    /// How is your Zodl experience?
    public static let ratingQuestion = L10n.tr("Localizable", "sendFeedback.ratingQuestion", fallback: "How is your Zodl experience?")
    /// Support
    public static let screenTitle = L10n.tr("Localizable", "sendFeedback.screenTitle", fallback: "Support")
    /// Send Us Feedback
    public static let title = L10n.tr("Localizable", "sendFeedback.title", fallback: "Send Us Feedback")
    public enum Share {
      /// Zodl
      public static let desc = L10n.tr("Localizable", "sendFeedback.share.desc", fallback: "Zodl")
      /// Your device doesn’t have an Apple email set up, so we prepared this message for you to send using your preferred email client. Please send this message to:
      public static let notAppleMailInfo = L10n.tr("Localizable", "sendFeedback.share.notAppleMailInfo", fallback: "Your device doesn’t have an Apple email set up, so we prepared this message for you to send using your preferred email client. Please send this message to:")
      /// Support message
      public static let title = L10n.tr("Localizable", "sendFeedback.share.title", fallback: "Support message")
    }
  }
  public enum SendSelect {
    /// CrossPay with Near
    public static let payWithNear = L10n.tr("Localizable", "sendSelect.payWithNear", fallback: "CrossPay with Near")
    /// Swap ZEC with NEAR Intents
    public static let swapWithNear = L10n.tr("Localizable", "sendSelect.swapWithNear", fallback: "Swap ZEC with NEAR Intents")
    public enum PayWithNear {
      /// Use shielded ZEC to send private cross-chain payments.
      public static let desc = L10n.tr("Localizable", "sendSelect.payWithNear.desc", fallback: "Use shielded ZEC to send private cross-chain payments.")
    }
    public enum SwapWithNear {
      /// Swap ZEC with other cryptocurrencies.
      public static let desc = L10n.tr("Localizable", "sendSelect.swapWithNear.desc", fallback: "Swap ZEC with other cryptocurrencies.")
    }
    public enum Zashi {
      /// Pay in ZEC
      public static let send = L10n.tr("Localizable", "sendSelect.zashi.send", fallback: "Pay in ZEC")
      public enum Send {
        /// Pay anyone by sending them ZEC.
        public static let desc = L10n.tr("Localizable", "sendSelect.zashi.send.desc", fallback: "Pay anyone by sending them ZEC.")
      }
    }
  }
  public enum ServerSetup {
    /// Active
    public static let active = L10n.tr("Localizable", "serverSetup.active", fallback: "Active")
    /// Browse all servers
    public static let allServers = L10n.tr("Localizable", "serverSetup.allServers", fallback: "Browse all servers")
    /// This may take a moment...
    public static let couldTakeTime = L10n.tr("Localizable", "serverSetup.couldTakeTime", fallback: "This may take a moment...")
    /// custom server
    public static let custom = L10n.tr("Localizable", "serverSetup.custom", fallback: "custom server")
    /// Default
    public static let `default` = L10n.tr("Localizable", "serverSetup.default", fallback: "Default")
    /// Fastest servers
    public static let fastestServers = L10n.tr("Localizable", "serverSetup.fastestServers", fallback: "Fastest servers")
    /// Other servers
    public static let otherServers = L10n.tr("Localizable", "serverSetup.otherServers", fallback: "Other servers")
    /// Performing Server Test
    public static let performingTest = L10n.tr("Localizable", "serverSetup.performingTest", fallback: "Performing Server Test")
    /// <hostname>:<port>
    public static let placeholder = L10n.tr("Localizable", "serverSetup.placeholder", fallback: "<hostname>:<port>")
    /// Refresh
    public static let refresh = L10n.tr("Localizable", "serverSetup.refresh", fallback: "Refresh")
    /// Save selection
    public static let save = L10n.tr("Localizable", "serverSetup.save", fallback: "Save selection")
    /// Server
    public static let title = L10n.tr("Localizable", "serverSetup.title", fallback: "Server")
    public enum Alert {
      public enum Failed {
        /// Error: %@
        public static func message(_ p1: Any) -> String {
          return L10n.tr("Localizable", "serverSetup.alert.failed.message", String(describing: p1), fallback: "Error: %@")
        }
        /// Invalid endpoint
        public static let title = L10n.tr("Localizable", "serverSetup.alert.failed.title", fallback: "Invalid endpoint")
      }
    }
  }
  public enum Settings {
    /// About
    public static let about = L10n.tr("Localizable", "settings.about", fallback: "About")
    /// Address Book
    public static let addressBook = L10n.tr("Localizable", "settings.addressBook", fallback: "Address Book")
    /// Advanced Settings
    public static let advanced = L10n.tr("Localizable", "settings.advanced", fallback: "Advanced Settings")
    /// Buy ZEC with Coinbase
    public static let buyZecCB = L10n.tr("Localizable", "settings.buyZecCB", fallback: "Buy ZEC with Coinbase")
    /// Choose a Server
    public static let chooseServer = L10n.tr("Localizable", "settings.chooseServer", fallback: "Choose a Server")
    /// A hassle-free way to buy ZEC and get it directly into your Zodl wallet.
    public static let coinbaseDesc = L10n.tr("Localizable", "settings.coinbaseDesc", fallback: "A hassle-free way to buy ZEC and get it directly into your Zodl wallet.")
    /// Currency Conversion
    public static let currencyConversion = L10n.tr("Localizable", "settings.currencyConversion", fallback: "Currency Conversion")
    /// Reset Zodl
    public static let deleteZashi = L10n.tr("Localizable", "settings.deleteZashi", fallback: "Reset Zodl")
    /// You will be asked to confirm on the next screen
    public static let deleteZashiWarning = L10n.tr("Localizable", "settings.deleteZashiWarning", fallback: "You will be asked to confirm on the next screen")
    /// Export logs only
    public static let exportLogsOnly = L10n.tr("Localizable", "settings.exportLogsOnly", fallback: "Export logs only")
    /// Export Private Data
    public static let exportPrivateData = L10n.tr("Localizable", "settings.exportPrivateData", fallback: "Export Private Data")
    /// Send Us Feedback
    public static let feedback = L10n.tr("Localizable", "settings.feedback", fallback: "Send Us Feedback")
    /// Pay with Flexa
    public static let flexa = L10n.tr("Localizable", "settings.flexa", fallback: "Pay with Flexa")
    /// Spend ZEC at thousands of retail locations.
    public static let flexaDesc = L10n.tr("Localizable", "settings.flexaDesc", fallback: "Spend ZEC at thousands of retail locations.")
    /// Integrations
    public static let integrations = L10n.tr("Localizable", "settings.integrations", fallback: "Integrations")
    /// Connect Keystone
    public static let keystone = L10n.tr("Localizable", "settings.keystone", fallback: "Connect Keystone")
    /// Connect airgapped hardware wallet to store shielded ZEC.
    public static let keystoneDesc = L10n.tr("Localizable", "settings.keystoneDesc", fallback: "Connect airgapped hardware wallet to store shielded ZEC.")
    /// Beta: Tor Protection
    public static let `private` = L10n.tr("Localizable", "settings.private", fallback: "Beta: Tor Protection")
    /// Zodl Recovery Phrase
    public static let recoveryPhrase = L10n.tr("Localizable", "settings.recoveryPhrase", fallback: "Zodl Recovery Phrase")
    /// During the Restore process, it is not possible to use payment integrations.
    public static let restoreWarning = L10n.tr("Localizable", "settings.restoreWarning", fallback: "During the Restore process, it is not possible to use payment integrations.")
    /// Settings
    public static let title = L10n.tr("Localizable", "settings.title", fallback: "Settings")
    /// Version %@ (%@)
    public static func version(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "settings.version", String(describing: p1), String(describing: p2), fallback: "Version %@ (%@)")
    }
    /// What's new
    public static let whatsNew = L10n.tr("Localizable", "settings.whatsNew", fallback: "What's new")
    public enum Alert {
      public enum CantSendEmail {
        /// Copy %@
        public static func copyEmail(_ p1: Any) -> String {
          return L10n.tr("Localizable", "settings.alert.cantSendEmail.copyEmail", String(describing: p1), fallback: "Copy %@")
        }
        /// It looks like you don't have a default email app configured on your device. Copy the address below, and use your favorite email client to send us a message.
        public static let message = L10n.tr("Localizable", "settings.alert.cantSendEmail.message", fallback: "It looks like you don't have a default email app configured on your device. Copy the address below, and use your favorite email client to send us a message.")
        /// Oh, no!
        public static let title = L10n.tr("Localizable", "settings.alert.cantSendEmail.title", fallback: "Oh, no!")
      }
    }
  }
  public enum Sheet {
    public enum InsufficientBalance {
      /// We couldn’t create this transaction for you. Your wallet doesn’t have enough balance to cover both the transaction amount and transaction fees. Please lower the transaction amount to account for the fees. 
      public static let msg = L10n.tr("Localizable", "sheet.insufficientBalance.msg", fallback: "We couldn’t create this transaction for you. Your wallet doesn’t have enough balance to cover both the transaction amount and transaction fees. Please lower the transaction amount to account for the fees. ")
      /// Insufficient Funds
      public static let title = L10n.tr("Localizable", "sheet.insufficientBalance.title", fallback: "Insufficient Funds")
    }
    public enum SyncTimeout {
      /// There was an error trying to execute the last operation. Check your connection, VPN setting, restart the app, or try one of the following:
      public static let desc = L10n.tr("Localizable", "sheet.syncTimeout.desc", fallback: "There was an error trying to execute the last operation. Check your connection, VPN setting, restart the app, or try one of the following:")
      /// Switch server
      public static let server = L10n.tr("Localizable", "sheet.syncTimeout.server", fallback: "Switch server")
      /// Something went wrong
      public static let title = L10n.tr("Localizable", "sheet.syncTimeout.title", fallback: "Something went wrong")
      /// Disable Tor protection
      public static let tor = L10n.tr("Localizable", "sheet.syncTimeout.tor", fallback: "Disable Tor protection")
    }
  }
  public enum ShieldFunds {
    public enum Error {
      /// Shielding Error
      public static let title = L10n.tr("Localizable", "shieldFunds.error.title", fallback: "Shielding Error")
      public enum Failure {
        /// An error happened during the last shielding transaction. You can try again later or report this issue if the problem persists. 
        /// 
        ///  %@
        public static func message(_ p1: Any) -> String {
          return L10n.tr("Localizable", "shieldFunds.error.failure.message", String(describing: p1), fallback: "An error happened during the last shielding transaction. You can try again later or report this issue if the problem persists. \n\n %@")
        }
      }
      public enum Gprc {
        /// An error happened during the last shielding transaction. We will try to resubmit the transaction later. If it fails, you may need to repeat the shielding attempt at a later time.
        public static let message = L10n.tr("Localizable", "shieldFunds.error.gprc.message", fallback: "An error happened during the last shielding transaction. We will try to resubmit the transaction later. If it fails, you may need to repeat the shielding attempt at a later time.")
      }
    }
  }
  public enum SmartBanner {
    public enum Content {
      public enum AutoShielding {
        /// Start
        public static let button = L10n.tr("Localizable", "smartBanner.content.autoShielding.button", fallback: "Start")
        /// Enable automatic shielding
        public static let info = L10n.tr("Localizable", "smartBanner.content.autoShielding.info", fallback: "Enable automatic shielding")
        /// Auto-Shielding
        public static let title = L10n.tr("Localizable", "smartBanner.content.autoShielding.title", fallback: "Auto-Shielding")
      }
      public enum Backup {
        /// Start
        public static let button = L10n.tr("Localizable", "smartBanner.content.backup.button", fallback: "Start")
        /// Prevent potential loss of funds
        public static let info = L10n.tr("Localizable", "smartBanner.content.backup.info", fallback: "Prevent potential loss of funds")
        /// Wallet Backup Required
        public static let title = L10n.tr("Localizable", "smartBanner.content.backup.title", fallback: "Wallet Backup Required")
      }
      public enum CurrencyConversion {
        /// Start
        public static let button = L10n.tr("Localizable", "smartBanner.content.currencyConversion.button", fallback: "Start")
        /// Enable to display USD values
        public static let info = L10n.tr("Localizable", "smartBanner.content.currencyConversion.info", fallback: "Enable to display USD values")
        /// Currency Conversion
        public static let title = L10n.tr("Localizable", "smartBanner.content.currencyConversion.title", fallback: "Currency Conversion")
      }
      public enum Disconnected {
        /// Check your connection and reload Zodl
        public static let info = L10n.tr("Localizable", "smartBanner.content.disconnected.info", fallback: "Check your connection and reload Zodl")
        /// Wallet Disconnected
        public static let title = L10n.tr("Localizable", "smartBanner.content.disconnected.title", fallback: "Wallet Disconnected")
      }
      public enum Restore {
        /// Keep Zodl open on active phone screen
        public static let info = L10n.tr("Localizable", "smartBanner.content.restore.info", fallback: "Keep Zodl open on active phone screen")
        /// Your funds are ready to be used now
        public static let infoSpendable = L10n.tr("Localizable", "smartBanner.content.restore.infoSpendable", fallback: "Your funds are ready to be used now")
        /// Restoring Wallet • %@ Complete
        public static func title(_ p1: Any) -> String {
          return L10n.tr("Localizable", "smartBanner.content.restore.title", String(describing: p1), fallback: "Restoring Wallet • %@ Complete")
        }
      }
      public enum Shield {
        /// Shield
        public static let button = L10n.tr("Localizable", "smartBanner.content.shield.button", fallback: "Shield")
        /// Transparent Balance Detected
        public static let title = L10n.tr("Localizable", "smartBanner.content.shield.title", fallback: "Transparent Balance Detected")
        /// Transparent Balance
        public static let titleShorter = L10n.tr("Localizable", "smartBanner.content.shield.titleShorter", fallback: "Transparent Balance")
      }
      public enum Sync {
        /// Your wallet is updating
        public static let info = L10n.tr("Localizable", "smartBanner.content.sync.info", fallback: "Your wallet is updating")
        /// Syncing • %@ Complete
        public static func title(_ p1: Any) -> String {
          return L10n.tr("Localizable", "smartBanner.content.sync.title", String(describing: p1), fallback: "Syncing • %@ Complete")
        }
      }
      public enum SyncingError {
        /// Attempting to resolve
        public static let info = L10n.tr("Localizable", "smartBanner.content.syncingError.info", fallback: "Attempting to resolve")
        /// Error encountered while syncing
        public static let title = L10n.tr("Localizable", "smartBanner.content.syncingError.title", fallback: "Error encountered while syncing")
      }
      public enum Tor {
        /// Review
        public static let button = L10n.tr("Localizable", "smartBanner.content.tor.button", fallback: "Review")
        /// Protect your IP address
        public static let info = L10n.tr("Localizable", "smartBanner.content.tor.info", fallback: "Protect your IP address")
        /// Beta: Enable Tor Protection
        public static let title = L10n.tr("Localizable", "smartBanner.content.tor.title", fallback: "Beta: Enable Tor Protection")
      }
      public enum UpdatingBalance {
        /// Waiting for last transaction to process
        public static let info = L10n.tr("Localizable", "smartBanner.content.updatingBalance.info", fallback: "Waiting for last transaction to process")
        /// Updating Balance...
        public static let title = L10n.tr("Localizable", "smartBanner.content.updatingBalance.title", fallback: "Updating Balance...")
      }
    }
    public enum Help {
      /// Remind me in 2 days
      public static let remindMePhase1 = L10n.tr("Localizable", "smartBanner.help.remindMePhase1", fallback: "Remind me in 2 days")
      /// Remind me in 2 weeks
      public static let remindMePhase2 = L10n.tr("Localizable", "smartBanner.help.remindMePhase2", fallback: "Remind me in 2 weeks")
      /// Remind me next month
      public static let remindMePhase3 = L10n.tr("Localizable", "smartBanner.help.remindMePhase3", fallback: "Remind me next month")
      public enum Backup {
        /// I read and understand the risks of not backing up my wallet.
        public static let acknowledge = L10n.tr("Localizable", "smartBanner.help.backup.acknowledge", fallback: "I read and understand the risks of not backing up my wallet.")
        /// Prevent potential loss of funds by securely backing up your wallet.
        public static let info1 = L10n.tr("Localizable", "smartBanner.help.backup.info1", fallback: "Prevent potential loss of funds by securely backing up your wallet.")
        /// Back up access to your funds by backing up:
        public static let info2 = L10n.tr("Localizable", "smartBanner.help.backup.info2", fallback: "Back up access to your funds by backing up:")
        /// In case you lose access to the app or to your device, knowing the Secret Recovery Phrase is the only way to recover your funds. We cannot see it and cannot help you recover it.
        public static let info3 = L10n.tr("Localizable", "smartBanner.help.backup.info3", fallback: "In case you lose access to the app or to your device, knowing the Secret Recovery Phrase is the only way to recover your funds. We cannot see it and cannot help you recover it.")
        /// Anyone with access to your Secret Recovery Phrase will have full control of your wallet, so keep it secure and never show it to anyone.
        public static let info4 = L10n.tr("Localizable", "smartBanner.help.backup.info4", fallback: "Anyone with access to your Secret Recovery Phrase will have full control of your wallet, so keep it secure and never show it to anyone.")
        /// Secret Recovery Phrase (a unique set of 24 words in a precise order) 
        public static let point1 = L10n.tr("Localizable", "smartBanner.help.backup.point1", fallback: "Secret Recovery Phrase (a unique set of 24 words in a precise order) ")
        /// Wallet Birthday Height (block height at which your wallet was created)
        public static let point2 = L10n.tr("Localizable", "smartBanner.help.backup.point2", fallback: "Wallet Birthday Height (block height at which your wallet was created)")
        /// Backup Required
        public static let title = L10n.tr("Localizable", "smartBanner.help.backup.title", fallback: "Backup Required")
      }
      public enum Diconnected {
        /// You appear to be offline. Please restore your internet connection to use Zodl wallet.
        public static let info = L10n.tr("Localizable", "smartBanner.help.diconnected.info", fallback: "You appear to be offline. Please restore your internet connection to use Zodl wallet.")
        /// Wallet Disconnected
        public static let title = L10n.tr("Localizable", "smartBanner.help.diconnected.title", fallback: "Wallet Disconnected")
      }
      public enum Restore {
        /// Zodl is scanning the blockchain to retrieve your transactions. Older wallets can take hours to restore. Follow these steps to prevent interruption:
        public static let info = L10n.tr("Localizable", "smartBanner.help.restore.info", fallback: "Zodl is scanning the blockchain to retrieve your transactions. Older wallets can take hours to restore. Follow these steps to prevent interruption:")
        /// Keep the Zodl app open on an active phone screen.
        public static let point1 = L10n.tr("Localizable", "smartBanner.help.restore.point1", fallback: "Keep the Zodl app open on an active phone screen.")
        /// To prevent your phone screen from going dark, turn off power-saving mode and keep your phone plugged in.
        public static let point2 = L10n.tr("Localizable", "smartBanner.help.restore.point2", fallback: "To prevent your phone screen from going dark, turn off power-saving mode and keep your phone plugged in.")
        /// Wallet Restore in Progress
        public static let title = L10n.tr("Localizable", "smartBanner.help.restore.title", fallback: "Wallet Restore in Progress")
        /// Funds cannot be spent until your wallet is restored.
        public static let warning = L10n.tr("Localizable", "smartBanner.help.restore.warning", fallback: "Funds cannot be spent until your wallet is restored.")
      }
      public enum Shield {
        /// Do not show this message again
        public static let doNotShowAgain = L10n.tr("Localizable", "smartBanner.help.shield.doNotShowAgain", fallback: "Do not show this message again")
        /// To protect user privacy, Zodl doesn't support spending transparent ZEC. Tap the "Shield" button below to make your transparent funds spendable and your total Zodl balance private. 
        public static let info1 = L10n.tr("Localizable", "smartBanner.help.shield.info1", fallback: "To protect user privacy, Zodl doesn't support spending transparent ZEC. Tap the \"Shield\" button below to make your transparent funds spendable and your total Zodl balance private. ")
        /// This will create a shielding in-wallet transaction, consolidating your transparent and shielded funds. (Typical fee: %@)
        public static func info2(_ p1: Any) -> String {
          return L10n.tr("Localizable", "smartBanner.help.shield.info2", String(describing: p1), fallback: "This will create a shielding in-wallet transaction, consolidating your transparent and shielded funds. (Typical fee: %@)")
        }
        /// Not now
        public static let notNow = L10n.tr("Localizable", "smartBanner.help.shield.notNow", fallback: "Not now")
        /// Always Shield Transparent Funds
        public static let title = L10n.tr("Localizable", "smartBanner.help.shield.title", fallback: "Always Shield Transparent Funds")
        /// Transparent
        public static let transparent = L10n.tr("Localizable", "smartBanner.help.shield.transparent", fallback: "Transparent")
      }
      public enum Sync {
        /// Zodl is scanning the blockchain for your latest transactions to make sure your balances are displayed correctly. Keep the Zodl app open on an active phone screen to avoid interruptions.
        public static let info = L10n.tr("Localizable", "smartBanner.help.sync.info", fallback: "Zodl is scanning the blockchain for your latest transactions to make sure your balances are displayed correctly. Keep the Zodl app open on an active phone screen to avoid interruptions.")
        /// Wallet Sync in Progress
        public static let title = L10n.tr("Localizable", "smartBanner.help.sync.title", fallback: "Wallet Sync in Progress")
      }
      public enum SyncError {
        /// Syncing Error
        public static let title = L10n.tr("Localizable", "smartBanner.help.syncError.title", fallback: "Syncing Error")
      }
      public enum UpdatingBalance {
        /// Your last transaction is getting mined and confirmed.
        public static let info = L10n.tr("Localizable", "smartBanner.help.updatingBalance.info", fallback: "Your last transaction is getting mined and confirmed.")
        /// Updating Balance
        public static let title = L10n.tr("Localizable", "smartBanner.help.updatingBalance.title", fallback: "Updating Balance")
      }
    }
  }
  public enum Splash {
    /// Tap the face icon to use Face ID and unlock it.
    public static let authFaceID = L10n.tr("Localizable", "splash.authFaceID", fallback: "Tap the face icon to use Face ID and unlock it.")
    /// Tap the key icon to enter your passcode and unlock it.
    public static let authPasscode = L10n.tr("Localizable", "splash.authPasscode", fallback: "Tap the key icon to enter your passcode and unlock it.")
    /// Your Zodl account is secured.
    public static let authTitle = L10n.tr("Localizable", "splash.authTitle", fallback: "Your Zodl account is secured.")
    /// Tap the print icon to use Touch ID and unlock it.
    public static let authTouchID = L10n.tr("Localizable", "splash.authTouchID", fallback: "Tap the print icon to use Touch ID and unlock it.")
  }
  public enum SupportData {
    public enum AppVersionItem {
      /// App identifier
      public static let bundleIdentifier = L10n.tr("Localizable", "supportData.appVersionItem.bundleIdentifier", fallback: "App identifier")
      /// App version
      public static let version = L10n.tr("Localizable", "supportData.appVersionItem.version", fallback: "App version")
    }
    public enum DeviceModelItem {
      /// Device
      public static let device = L10n.tr("Localizable", "supportData.deviceModelItem.device", fallback: "Device")
    }
    public enum FreeDiskSpaceItem {
      /// Usable storage
      public static let freeDiskSpace = L10n.tr("Localizable", "supportData.freeDiskSpaceItem.freeDiskSpace", fallback: "Usable storage")
    }
    public enum LocaleItem {
      /// Currency decimal separator
      public static let decimalSeparator = L10n.tr("Localizable", "supportData.localeItem.decimalSeparator", fallback: "Currency decimal separator")
      /// Currency grouping separator
      public static let groupingSeparator = L10n.tr("Localizable", "supportData.localeItem.groupingSeparator", fallback: "Currency grouping separator")
      /// Locale
      public static let locale = L10n.tr("Localizable", "supportData.localeItem.locale", fallback: "Locale")
    }
    public enum PermissionItem {
      /// Camera access
      public static let camera = L10n.tr("Localizable", "supportData.permissionItem.camera", fallback: "Camera access")
      /// FaceID available
      public static let faceID = L10n.tr("Localizable", "supportData.permissionItem.faceID", fallback: "FaceID available")
      /// Permissions
      public static let permissions = L10n.tr("Localizable", "supportData.permissionItem.permissions", fallback: "Permissions")
      /// TouchID available
      public static let touchID = L10n.tr("Localizable", "supportData.permissionItem.touchID", fallback: "TouchID available")
    }
    public enum SystemVersionItem {
      /// iOS version
      public static let version = L10n.tr("Localizable", "supportData.systemVersionItem.version", fallback: "iOS version")
    }
    public enum TimeItem {
      /// Current time
      public static let time = L10n.tr("Localizable", "supportData.timeItem.time", fallback: "Current time")
    }
  }
  public enum Swap {
    /// near
    public static let nearProvider = L10n.tr("Localizable", "swap.nearProvider", fallback: "near")
    /// We tried but couldn’t get a quote for a payment with your parameters. You can try to adjust the slippage or try again later.
    public static let quoteUnavailable = L10n.tr("Localizable", "swap.quoteUnavailable", fallback: "We tried but couldn’t get a quote for a payment with your parameters. You can try to adjust the slippage or try again later.")
    /// We tried but couldn’t get a quote for a swap with your parameters. You can try to adjust the slippage or try again later.
    public static let quoteUnavailableSwap = L10n.tr("Localizable", "swap.quoteUnavailableSwap", fallback: "We tried but couldn’t get a quote for a swap with your parameters. You can try to adjust the slippage or try again later.")
  }
  public enum SwapAndPay {
    /// Address
    public static let address = L10n.tr("Localizable", "swapAndPay.address", fallback: "Address")
    /// Add new contact
    public static let addressBookNewContact = L10n.tr("Localizable", "swapAndPay.addressBookNewContact", fallback: "Add new contact")
    /// Select...
    public static let addressBookSelect = L10n.tr("Localizable", "swapAndPay.addressBookSelect", fallback: "Select...")
    /// Select Chain
    public static let addressBookSelectChain = L10n.tr("Localizable", "swapAndPay.addressBookSelectChain", fallback: "Select Chain")
    /// Zcash address is not allowed
    public static let addressBookZcash = L10n.tr("Localizable", "swapAndPay.addressBookZcash", fallback: "Zcash address is not allowed")
    /// Don’t cancel
    public static let cancelDont = L10n.tr("Localizable", "swapAndPay.cancelDont", fallback: "Don’t cancel")
    /// If you leave this screen, all the information you entered will be lost.
    public static let cancelMsg = L10n.tr("Localizable", "swapAndPay.cancelMsg", fallback: "If you leave this screen, all the information you entered will be lost.")
    /// Cancel payment
    public static let cancelPayment = L10n.tr("Localizable", "swapAndPay.cancelPayment", fallback: "Cancel payment")
    /// Cancel swap
    public static let cancelSwap = L10n.tr("Localizable", "swapAndPay.cancelSwap", fallback: "Cancel swap")
    /// Are you sure?
    public static let canceltitle = L10n.tr("Localizable", "swapAndPay.canceltitle", fallback: "Are you sure?")
    /// Check status
    public static let checkStatus = L10n.tr("Localizable", "swapAndPay.checkStatus", fallback: "Check status")
    /// Custom
    public static let custom = L10n.tr("Localizable", "swapAndPay.custom", fallback: "Custom")
    /// Enter custom slippage
    public static let customSlippage = L10n.tr("Localizable", "swapAndPay.customSlippage", fallback: "Enter custom slippage")
    /// Edit payment
    public static let editPayment = L10n.tr("Localizable", "swapAndPay.editPayment", fallback: "Edit payment")
    /// Edit swap
    public static let editSwap = L10n.tr("Localizable", "swapAndPay.editSwap", fallback: "Edit swap")
    /// Enter address...
    public static let enterAddress = L10n.tr("Localizable", "swapAndPay.enterAddress", fallback: "Enter address...")
    /// Realized slippage
    public static let executedSlippage = L10n.tr("Localizable", "swapAndPay.executedSlippage", fallback: "Realized slippage")
    /// There was an error initiating a cross-chain payment. Try it again, please.
    public static let failurePayInfo = L10n.tr("Localizable", "swapAndPay.failurePayInfo", fallback: "There was an error initiating a cross-chain payment. Try it again, please.")
    /// There was an error initiating a swap. Try it again, please.
    public static let failureSwapInfo = L10n.tr("Localizable", "swapAndPay.failureSwapInfo", fallback: "There was an error initiating a swap. Try it again, please.")
    /// ZEC transaction fee
    public static let fee = L10n.tr("Localizable", "swapAndPay.fee", fallback: "ZEC transaction fee")
    /// From
    public static let from = L10n.tr("Localizable", "swapAndPay.from", fallback: "From")
    /// Get a quote
    public static let getQuote = L10n.tr("Localizable", "swapAndPay.getQuote", fallback: "Get a quote")
    /// Spendable: %@
    public static func max(_ p1: Any) -> String {
      return L10n.tr("Localizable", "swapAndPay.max", String(describing: p1), fallback: "Spendable: %@")
    }
    /// Please enter maximum slippage of
    public static let maxAllowedSlippage1 = L10n.tr("Localizable", "swapAndPay.maxAllowedSlippage1", fallback: "Please enter maximum slippage of")
    ///  %@.
    public static func maxAllowedSlippage2(_ p1: Any) -> String {
      return L10n.tr("Localizable", "swapAndPay.maxAllowedSlippage2", String(describing: p1), fallback: " %@.")
    }
    /// Max slippage %@%
    public static func maxSlippage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "swapAndPay.maxSlippage", String(describing: p1), fallback: "Max slippage %@%")
    }
    /// Max slippage
    public static let maxSlippageTitle = L10n.tr("Localizable", "swapAndPay.maxSlippageTitle", fallback: "Max slippage")
    /// 1 ZEC = %@ %@
    public static func oneZecRate(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "swapAndPay.oneZecRate", String(describing: p1), String(describing: p2), fallback: "1 ZEC = %@ %@")
    }
    /// Pay
    public static let pay = L10n.tr("Localizable", "swapAndPay.pay", fallback: "Pay")
    /// Pay from
    public static let payFrom = L10n.tr("Localizable", "swapAndPay.payFrom", fallback: "Pay from")
    /// Pay Now
    public static let payNow = L10n.tr("Localizable", "swapAndPay.payNow", fallback: "Pay Now")
    /// Pay to
    public static let payTo = L10n.tr("Localizable", "swapAndPay.payTo", fallback: "Pay to")
    /// Your cross-chain payment is being processed. Follow its status on the transaction screen.
    public static let pendingPayInfo = L10n.tr("Localizable", "swapAndPay.pendingPayInfo", fallback: "Your cross-chain payment is being processed. Follow its status on the transaction screen.")
    /// Payment Pending
    public static let pendingPayTitle = L10n.tr("Localizable", "swapAndPay.pendingPayTitle", fallback: "Payment Pending")
    /// Your swap is being processed. Follow its status on the transaction screen.
    public static let pendingSwapInfo = L10n.tr("Localizable", "swapAndPay.pendingSwapInfo", fallback: "Your swap is being processed. Follow its status on the transaction screen.")
    /// Swap Pending
    public static let pendingSwapTitle = L10n.tr("Localizable", "swapAndPay.pendingSwapTitle", fallback: "Swap Pending")
    /// Quote Unavailable
    public static let quoteUnavailable = L10n.tr("Localizable", "swapAndPay.quoteUnavailable", fallback: "Quote Unavailable")
    /// Rate
    public static let rate = L10n.tr("Localizable", "swapAndPay.rate", fallback: "Rate")
    /// Recipient
    public static let recipient = L10n.tr("Localizable", "swapAndPay.recipient", fallback: "Recipient")
    /// Recipient gets
    public static let recipientGets = L10n.tr("Localizable", "swapAndPay.recipientGets", fallback: "Recipient gets")
    /// Refunded amount
    public static let refundedAmount = L10n.tr("Localizable", "swapAndPay.refundedAmount", fallback: "Refunded amount")
    /// Your deposit transaction was sent but the swap was unsuccessful. The transaction amount has been refunded, minus transaction fees.
    public static let refundInfo = L10n.tr("Localizable", "swapAndPay.refundInfo", fallback: "Your deposit transaction was sent but the swap was unsuccessful. The transaction amount has been refunded, minus transaction fees.")
    /// Transaction Refunded
    public static let refundTitle = L10n.tr("Localizable", "swapAndPay.refundTitle", fallback: "Transaction Refunded")
    /// Search by name or ticker...
    public static let search = L10n.tr("Localizable", "swapAndPay.search", fallback: "Search by name or ticker...")
    /// Select...
    public static let select = L10n.tr("Localizable", "swapAndPay.select", fallback: "Select...")
    /// Select asset
    public static let selectToken = L10n.tr("Localizable", "swapAndPay.selectToken", fallback: "Select asset")
    /// Your coins are being sent to the deposit address...
    public static let sendingInfo = L10n.tr("Localizable", "swapAndPay.sendingInfo", fallback: "Your coins are being sent to the deposit address...")
    /// Slippage
    public static let slippage = L10n.tr("Localizable", "swapAndPay.slippage", fallback: "Slippage")
    /// This setting determines the maximum allowable difference between the expected price of a swap and the actual price you pay, which is outside of Zodl's control.
    public static let slippageDesc = L10n.tr("Localizable", "swapAndPay.slippageDesc", fallback: "This setting determines the maximum allowable difference between the expected price of a swap and the actual price you pay, which is outside of Zodl's control.")
    /// You may receive up to 
    public static let slippageSet1 = L10n.tr("Localizable", "swapAndPay.slippageSet1", fallback: "You may receive up to ")
    /// %@% (%@)
    public static func slippageSet2a(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "swapAndPay.slippageSet2a", String(describing: p1), String(describing: p2), fallback: "%@% (%@)")
    }
    /// %@%
    public static func slippageSet2b(_ p1: Any) -> String {
      return L10n.tr("Localizable", "swapAndPay.slippageSet2b", String(describing: p1), fallback: "%@%")
    }
    ///  less than quoted.
    public static let slippageSet3 = L10n.tr("Localizable", "swapAndPay.slippageSet3", fallback: " less than quoted.")
    /// Slippage tolerance
    public static let slippageTolerance = L10n.tr("Localizable", "swapAndPay.slippageTolerance", fallback: "Slippage tolerance")
    /// Any unused portion of the slippage fee will be refunded if the swap executes with lower slippage than expected.
    public static let slippageWarn = L10n.tr("Localizable", "swapAndPay.slippageWarn", fallback: "Any unused portion of the slippage fee will be refunded if the swap executes with lower slippage than expected.")
    /// Status
    public static let status = L10n.tr("Localizable", "swapAndPay.status", fallback: "Status")
    /// You successfully initiated a cross-chain payment. Follow its status on the transaction screen.
    public static let successPayInfo = L10n.tr("Localizable", "swapAndPay.successPayInfo", fallback: "You successfully initiated a cross-chain payment. Follow its status on the transaction screen.")
    /// You successfully initiated a swap. Follow its status on the transaction screen.
    public static let successSwapInfo = L10n.tr("Localizable", "swapAndPay.successSwapInfo", fallback: "You successfully initiated a swap. Follow its status on the transaction screen.")
    /// Swap
    public static let swap = L10n.tr("Localizable", "swapAndPay.swap", fallback: "Swap")
    /// Swap from
    public static let swapFrom = L10n.tr("Localizable", "swapAndPay.swapFrom", fallback: "Swap from")
    /// Swap Now
    public static let swapNow = L10n.tr("Localizable", "swapAndPay.swapNow", fallback: "Swap Now")
    /// You could receive up to %@ less based on the %@ slippage you set.
    public static func swapQuoteSlippageWarn(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "swapAndPay.swapQuoteSlippageWarn", String(describing: p1), String(describing: p2), fallback: "You could receive up to %@ less based on the %@ slippage you set.")
    }
    /// Swap to
    public static let swapTo = L10n.tr("Localizable", "swapAndPay.swapTo", fallback: "Swap to")
    /// Swap or  Pay with
    public static let title = L10n.tr("Localizable", "swapAndPay.title", fallback: "Swap or  Pay with")
    /// To
    public static let to = L10n.tr("Localizable", "swapAndPay.to", fallback: "To")
    /// Total Amount
    public static let totalAmount = L10n.tr("Localizable", "swapAndPay.totalAmount", fallback: "Total Amount")
    /// Total fees
    public static let totalFees = L10n.tr("Localizable", "swapAndPay.totalFees", fallback: "Total fees")
    /// You pay
    public static let youPay = L10n.tr("Localizable", "swapAndPay.youPay", fallback: "You pay")
    /// Zodl fee
    public static let zashiFee = L10n.tr("Localizable", "swapAndPay.zashiFee", fallback: "Zodl fee")
    public enum EmptyAssets {
      /// We tried but couldn’t find anything.
      public static let subtitle = L10n.tr("Localizable", "swapAndPay.emptyAssets.subtitle", fallback: "We tried but couldn’t find anything.")
      /// No results
      public static let title = L10n.tr("Localizable", "swapAndPay.emptyAssets.title", fallback: "No results")
    }
    public enum Failure {
      /// Please try again later.
      public static let laterDesc = L10n.tr("Localizable", "swapAndPay.failure.laterDesc", fallback: "Please try again later.")
      /// The service is unavailable
      public static let laterTitle = L10n.tr("Localizable", "swapAndPay.failure.laterTitle", fallback: "The service is unavailable")
      /// Please check your connection and try again.
      public static let retryDesc = L10n.tr("Localizable", "swapAndPay.failure.retryDesc", fallback: "Please check your connection and try again.")
      /// Unexpected error
      public static let retryTitle = L10n.tr("Localizable", "swapAndPay.failure.retryTitle", fallback: "Unexpected error")
      /// Try again
      public static let tryAgain = L10n.tr("Localizable", "swapAndPay.failure.tryAgain", fallback: "Try again")
      /// Something went wrong
      public static let wrong = L10n.tr("Localizable", "swapAndPay.failure.wrong", fallback: "Something went wrong")
      /// We couldn’t load the assets. Please check your connection and try again.
      public static let wrongDesc = L10n.tr("Localizable", "swapAndPay.failure.wrongDesc", fallback: "We couldn’t load the assets. Please check your connection and try again.")
    }
    public enum ForcedOptIn {
      /// I understand that Zodl makes API requests to the NEAR API every time I interact with a Swap/Pay transaction.
      public static let optionOne = L10n.tr("Localizable", "swapAndPay.forcedOptIn.optionOne", fallback: "I understand that Zodl makes API requests to the NEAR API every time I interact with a Swap/Pay transaction.")
      /// I understand that by not enabling Tor, my IP address will be leaked by the NEAR API.
      public static let optionTwo = L10n.tr("Localizable", "swapAndPay.forcedOptIn.optionTwo", fallback: "I understand that by not enabling Tor, my IP address will be leaked by the NEAR API.")
    }
    public enum Help {
      /// Make cross-chain payments in any NEAR-supported coin or token.
      public static let payDesc1 = L10n.tr("Localizable", "swapAndPay.help.payDesc1", fallback: "Make cross-chain payments in any NEAR-supported coin or token.")
      /// If the actual slippage and network conditions result in your recipient receiving less than the promised amount, your transaction will be reversed. You will receive a full refund minus network fees.
      public static let payDesc2 = L10n.tr("Localizable", "swapAndPay.help.payDesc2", fallback: "If the actual slippage and network conditions result in your recipient receiving less than the promised amount, your transaction will be reversed. You will receive a full refund minus network fees.")
      /// Pay with
      public static let payWith = L10n.tr("Localizable", "swapAndPay.help.payWith", fallback: "Pay with")
      /// Pay with NEAR
      public static let payWithNear = L10n.tr("Localizable", "swapAndPay.help.payWithNear", fallback: "Pay with NEAR")
      /// Swap ZEC with any NEAR-supported token. 
      public static let swapDesc = L10n.tr("Localizable", "swapAndPay.help.swapDesc", fallback: "Swap ZEC with any NEAR-supported token. ")
      /// If swapping TO ZEC, you will send funds from a 3rd party wallet and provide an address where change can be refunded.
      public static let swapDesc1 = L10n.tr("Localizable", "swapAndPay.help.swapDesc1", fallback: "If swapping TO ZEC, you will send funds from a 3rd party wallet and provide an address where change can be refunded.")
      /// If swapping FROM ZEC, you must provide a valid address for the asset you are swapping to.
      public static let swapDesc2 = L10n.tr("Localizable", "swapAndPay.help.swapDesc2", fallback: "If swapping FROM ZEC, you must provide a valid address for the asset you are swapping to.")
      /// Swap with
      public static let swapWith = L10n.tr("Localizable", "swapAndPay.help.swapWith", fallback: "Swap with")
      /// Swap with NEAR
      public static let swapWithNear = L10n.tr("Localizable", "swapAndPay.help.swapWithNear", fallback: "Swap with NEAR")
    }
    public enum OptIn {
      /// This feature is powered by a third-party NEAR API. Zodl needs to make networking calls to fetch rates, quotes, execute transactions and check their status in the transaction history which can leak your IP address. We recommend you to allow Tor connection to protect your IP address at all times.
      public static let desc = L10n.tr("Localizable", "swapAndPay.optIn.desc", fallback: "This feature is powered by a third-party NEAR API. Zodl needs to make networking calls to fetch rates, quotes, execute transactions and check their status in the transaction history which can leak your IP address. We recommend you to allow Tor connection to protect your IP address at all times.")
      /// Enable API calls to the NEAR API.
      public static let optionOneSubtitle = L10n.tr("Localizable", "swapAndPay.optIn.optionOneSubtitle", fallback: "Enable API calls to the NEAR API.")
      /// Allow Third-Party Requests
      public static let optionOneTitle = L10n.tr("Localizable", "swapAndPay.optIn.optionOneTitle", fallback: "Allow Third-Party Requests")
      /// Protect IP address with Tor connection.
      public static let optionTwoSubtitle = L10n.tr("Localizable", "swapAndPay.optIn.optionTwoSubtitle", fallback: "Protect IP address with Tor connection.")
      /// Turn on IP Address Protection
      public static let optionTwoTitle = L10n.tr("Localizable", "swapAndPay.optIn.optionTwoTitle", fallback: "Turn on IP Address Protection")
      /// Swap or Pay with
      public static let title = L10n.tr("Localizable", "swapAndPay.optIn.title", fallback: "Swap or Pay with")
      /// Note for the super privacy-conscious: Transactions executed via the NEAR API are transparent which means all transaction information is public.
      public static let warn = L10n.tr("Localizable", "swapAndPay.optIn.warn", fallback: "Note for the super privacy-conscious: Transactions executed via the NEAR API are transparent which means all transaction information is public.")
    }
    public enum Quote {
      /// Zodl
      public static let zashi = L10n.tr("Localizable", "swapAndPay.quote.zashi", fallback: "Zodl")
    }
    public enum Status {
      /// Expired
      public static let expired = L10n.tr("Localizable", "swapAndPay.status.expired", fallback: "Expired")
      /// Failed
      public static let failed = L10n.tr("Localizable", "swapAndPay.status.failed", fallback: "Failed")
      /// Pending
      public static let pending = L10n.tr("Localizable", "swapAndPay.status.pending", fallback: "Pending")
      /// Pending Deposit
      public static let pendingDeposit = L10n.tr("Localizable", "swapAndPay.status.pendingDeposit", fallback: "Pending Deposit")
      /// Processing
      public static let processing = L10n.tr("Localizable", "swapAndPay.status.processing", fallback: "Processing")
      /// Refunded
      public static let refunded = L10n.tr("Localizable", "swapAndPay.status.refunded", fallback: "Refunded")
      /// Completed
      public static let success = L10n.tr("Localizable", "swapAndPay.status.success", fallback: "Completed")
    }
  }
  public enum SwapStatus {
    /// Paid
    public static let paid = L10n.tr("Localizable", "swapStatus.paid", fallback: "Paid")
    /// Paying
    public static let paying = L10n.tr("Localizable", "swapStatus.paying", fallback: "Paying")
    /// Payment Expired
    public static let paymentExpired = L10n.tr("Localizable", "swapStatus.paymentExpired", fallback: "Payment Expired")
    /// Payment Failed
    public static let paymentFailed = L10n.tr("Localizable", "swapStatus.paymentFailed", fallback: "Payment Failed")
    /// Payment Refunded
    public static let paymentRefunded = L10n.tr("Localizable", "swapStatus.paymentRefunded", fallback: "Payment Refunded")
    /// Swap Expired
    public static let swapExpired = L10n.tr("Localizable", "swapStatus.swapExpired", fallback: "Swap Expired")
    /// Swap Failed
    public static let swapFailed = L10n.tr("Localizable", "swapStatus.swapFailed", fallback: "Swap Failed")
    /// Swapped
    public static let swapped = L10n.tr("Localizable", "swapStatus.swapped", fallback: "Swapped")
    /// Swapping
    public static let swapping = L10n.tr("Localizable", "swapStatus.swapping", fallback: "Swapping")
    /// Swap Refunded
    public static let swapRefunded = L10n.tr("Localizable", "swapStatus.swapRefunded", fallback: "Swap Refunded")
  }
  public enum SwapToZec {
    /// %@ address...
    public static func address(_ p1: Any) -> String {
      return L10n.tr("Localizable", "swapToZec.address", String(describing: p1), fallback: "%@ address...")
    }
    /// Deposit Amount
    public static let deposit = L10n.tr("Localizable", "swapToZec.deposit", fallback: "Deposit Amount")
    /// Deposit to
    public static let depositTo = L10n.tr("Localizable", "swapToZec.depositTo", fallback: "Deposit to")
    /// Use your 
    public static let info1 = L10n.tr("Localizable", "swapToZec.info1", fallback: "Use your ")
    /// %@ on %@
    public static func info2(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "swapToZec.info2", String(describing: p1), String(describing: p2), fallback: "%@ on %@")
    }
    ///  wallet to deposit funds. Depositing other assets may result in loss of funds.
    public static let info3 = L10n.tr("Localizable", "swapToZec.info3", fallback: " wallet to deposit funds. Depositing other assets may result in loss of funds.")
    /// Refund Address
    public static let refundAddress = L10n.tr("Localizable", "swapToZec.refundAddress", fallback: "Refund Address")
    /// Review Quote
    public static let review = L10n.tr("Localizable", "swapToZec.review", fallback: "Review Quote")
    /// I’ve sent the funds
    public static let sentTheFunds = L10n.tr("Localizable", "swapToZec.sentTheFunds", fallback: "I’ve sent the funds")
    /// Share QR
    public static let shareQR = L10n.tr("Localizable", "swapToZec.shareQR", fallback: "Share QR")
    /// Swap Completed
    public static let swapCompleted = L10n.tr("Localizable", "swapToZec.swapCompleted", fallback: "Swap Completed")
    /// Swap Details
    public static let swapDetails = L10n.tr("Localizable", "swapToZec.swapDetails", fallback: "Swap Details")
    /// Swap Expired
    public static let swapExpired = L10n.tr("Localizable", "swapToZec.swapExpired", fallback: "Swap Expired")
    /// Swap Failed
    public static let swapFailed = L10n.tr("Localizable", "swapToZec.swapFailed", fallback: "Swap Failed")
    /// Swap Pending
    public static let swapPending = L10n.tr("Localizable", "swapToZec.swapPending", fallback: "Swap Pending")
    /// Swap Processing
    public static let swapProcessing = L10n.tr("Localizable", "swapToZec.swapProcessing", fallback: "Swap Processing")
    /// Swap Refunded
    public static let swapRefunded = L10n.tr("Localizable", "swapToZec.swapRefunded", fallback: "Swap Refunded")
    public enum RefundAddress {
      /// If the swap fails or market conditions change, your transaction may be refunded minus the transaction fees.
      public static let msg1 = L10n.tr("Localizable", "swapToZec.refundAddress.msg1", fallback: "If the swap fails or market conditions change, your transaction may be refunded minus the transaction fees.")
      /// The refunded amount will be returned to your wallet in the source currency - USDC on NEAR. Please enter a valid address to avoid loss of funds.
      public static let msg2 = L10n.tr("Localizable", "swapToZec.refundAddress.msg2", fallback: "The refunded amount will be returned to your wallet in the source currency - USDC on NEAR. Please enter a valid address to avoid loss of funds.")
      /// Refund Address
      public static let title = L10n.tr("Localizable", "swapToZec.refundAddress.title", fallback: "Refund Address")
    }
    public enum Share {
      /// Deposit address for %@ %@ on Near swap to ZEC in Zodl.
      public static func msg(_ p1: Any, _ p2: Any) -> String {
        return L10n.tr("Localizable", "swapToZec.share.msg", String(describing: p1), String(describing: p2), fallback: "Deposit address for %@ %@ on Near swap to ZEC in Zodl.")
      }
      /// Swap Deposit Address
      public static let title = L10n.tr("Localizable", "swapToZec.share.title", fallback: "Swap Deposit Address")
    }
  }
  public enum Sync {
    public enum Alert {
      /// Error
      public static let title = L10n.tr("Localizable", "sync.alert.title", fallback: "Error")
    }
    public enum Message {
      /// Error: %@
      public static func error(_ p1: Any) -> String {
        return L10n.tr("Localizable", "sync.message.error", String(describing: p1), fallback: "Error: %@")
      }
      /// Stopped
      public static let stopped = L10n.tr("Localizable", "sync.message.stopped", fallback: "Stopped")
      /// %@%% Synced
      public static func sync(_ p1: Any) -> String {
        return L10n.tr("Localizable", "sync.message.sync", String(describing: p1), fallback: "%@%% Synced")
      }
      /// Unprepared
      public static let unprepared = L10n.tr("Localizable", "sync.message.unprepared", fallback: "Unprepared")
      /// Up-To-Date
      public static let uptodate = L10n.tr("Localizable", "sync.message.uptodate", fallback: "Up-To-Date")
    }
  }
  public enum Tabs {
    /// Account
    public static let account = L10n.tr("Localizable", "tabs.account", fallback: "Account")
    /// Balances
    public static let balances = L10n.tr("Localizable", "tabs.balances", fallback: "Balances")
    /// Receive
    public static let receive = L10n.tr("Localizable", "tabs.receive", fallback: "Receive")
    /// Receive ZEC
    public static let receiveZec = L10n.tr("Localizable", "tabs.receiveZec", fallback: "Receive ZEC")
    /// Send
    public static let send = L10n.tr("Localizable", "tabs.send", fallback: "Send")
  }
  public enum TaxExport {
    /// Download your %@ transaction history from the previous calendar year in a .csv format.
    public static func desc(_ p1: Any) -> String {
      return L10n.tr("Localizable", "taxExport.desc", String(describing: p1), fallback: "Download your %@ transaction history from the previous calendar year in a .csv format.")
    }
    /// Download
    public static let download = L10n.tr("Localizable", "taxExport.download", fallback: "Download")
    /// %@_transaction_history_%@.csv
    public static func fileName(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "taxExport.fileName", String(describing: p1), String(describing: p2), fallback: "%@_transaction_history_%@.csv")
    }
    /// %@ transaction history
    public static func shareDesc(_ p1: Any) -> String {
      return L10n.tr("Localizable", "taxExport.shareDesc", String(describing: p1), fallback: "%@ transaction history")
    }
    /// Export Tax File
    public static let taxFile = L10n.tr("Localizable", "taxExport.taxFile", fallback: "Export Tax File")
    /// Data Export
    public static let title = L10n.tr("Localizable", "taxExport.title", fallback: "Data Export")
  }
  public enum TexKeystone {
    /// Got it
    public static let gotIt = L10n.tr("Localizable", "texKeystone.gotIt", fallback: "Got it")
    /// Step %@
    public static func step(_ p1: Any) -> String {
      return L10n.tr("Localizable", "texKeystone.step", String(describing: p1), fallback: "Step %@")
    }
    /// Unsupported Address Type
    public static let title = L10n.tr("Localizable", "texKeystone.title", fallback: "Unsupported Address Type")
    /// Keystone doesn't currently support transfers to Binance TEX addresses. 
    public static let warn1 = L10n.tr("Localizable", "texKeystone.warn1", fallback: "Keystone doesn't currently support transfers to Binance TEX addresses. ")
    /// Please use the steps below to complete your transaction.
    public static let warn2 = L10n.tr("Localizable", "texKeystone.warn2", fallback: "Please use the steps below to complete your transaction.")
    /// Workaround Steps
    public static let workaround = L10n.tr("Localizable", "texKeystone.workaround", fallback: "Workaround Steps")
    public enum Step1 {
      /// Transfer ZEC to your Zodl shielded address
      public static let desc = L10n.tr("Localizable", "texKeystone.step1.desc", fallback: "Transfer ZEC to your Zodl shielded address")
      /// Send to Zodl first
      public static let title = L10n.tr("Localizable", "texKeystone.step1.title", fallback: "Send to Zodl first")
    }
    public enum Step2 {
      /// Once received in Zodl, send the tokens to your final TEX destination address
      public static let desc = L10n.tr("Localizable", "texKeystone.step2.desc", fallback: "Once received in Zodl, send the tokens to your final TEX destination address")
      /// Send from Zodl to TEX address
      public static let title = L10n.tr("Localizable", "texKeystone.step2.title", fallback: "Send from Zodl to TEX address")
    }
  }
  public enum Tooltip {
    public enum ExchangeRate {
      /// We tried but we couldn’t refresh the exchange rate for you. Check your connection, relaunch the app, and we’ll try again.
      public static let desc = L10n.tr("Localizable", "tooltip.exchangeRate.desc", fallback: "We tried but we couldn’t refresh the exchange rate for you. Check your connection, relaunch the app, and we’ll try again.")
      /// Exchange rate unavailable
      public static let title = L10n.tr("Localizable", "tooltip.exchangeRate.title", fallback: "Exchange rate unavailable")
    }
  }
  public enum TorSettingsSheet {
    /// Routes your connection through the Tor network for enhanced anonymity and privacy protection.
    public static let desc = L10n.tr("Localizable", "torSettingsSheet.desc", fallback: "Routes your connection through the Tor network for enhanced anonymity and privacy protection.")
    /// If Tor is available in your region, we recommend enabling it for enhanced privacy during wallet restoration. This step is completely optional.
    public static let msg = L10n.tr("Localizable", "torSettingsSheet.msg", fallback: "If Tor is available in your region, we recommend enabling it for enhanced privacy during wallet restoration. This step is completely optional.")
    /// Enable Tor Protection
    public static let title = L10n.tr("Localizable", "torSettingsSheet.title", fallback: "Enable Tor Protection")
  }
  public enum TorSetup {
    /// Don’t connect over Tor.
    public static let disableDesc = L10n.tr("Localizable", "torSetup.disableDesc", fallback: "Don’t connect over Tor.")
    /// Connect over Tor.
    public static let enableDesc = L10n.tr("Localizable", "torSetup.enableDesc", fallback: "Connect over Tor.")
    /// Beta: Tor Protection
    public static let title = L10n.tr("Localizable", "torSetup.title", fallback: "Beta: Tor Protection")
    public enum Alert {
      /// Disable
      public static let disable = L10n.tr("Localizable", "torSetup.alert.disable", fallback: "Disable")
      /// Don’t disable
      public static let dontDisable = L10n.tr("Localizable", "torSetup.alert.dontDisable", fallback: "Don’t disable")
      /// Tor connection issues detected. To improve performance, try disabling Tor. This will stop exchange rate updates. You can re-enable it later in Advanced Settings.
      public static let msg = L10n.tr("Localizable", "torSetup.alert.msg", fallback: "Tor connection issues detected. To improve performance, try disabling Tor. This will stop exchange rate updates. You can re-enable it later in Advanced Settings.")
      /// Disable Tor?
      public static let title = L10n.tr("Localizable", "torSetup.alert.title", fallback: "Disable Tor?")
    }
    public enum CcSheet {
      /// Tor Protection is a beta feature that provides additional protections for your IP address. USD exchange rates are only available when it is enabled.
      public static let desc1 = L10n.tr("Localizable", "torSetup.ccSheet.desc1", fallback: "Tor Protection is a beta feature that provides additional protections for your IP address. USD exchange rates are only available when it is enabled.")
      /// If Tor is permitted in your region, we recommend enabling it. You can manage it in Advanced Settings.
      public static let desc2 = L10n.tr("Localizable", "torSetup.ccSheet.desc2", fallback: "If Tor is permitted in your region, we recommend enabling it. You can manage it in Advanced Settings.")
      /// Enable
      public static let enable = L10n.tr("Localizable", "torSetup.ccSheet.enable", fallback: "Enable")
      /// Do it later
      public static let later = L10n.tr("Localizable", "torSetup.ccSheet.later", fallback: "Do it later")
      /// Tor Required for Currency Conversion
      public static let title = L10n.tr("Localizable", "torSetup.ccSheet.title", fallback: "Tor Required for Currency Conversion")
    }
    public enum Learn {
      /// Opt in
      public static let btnIn = L10n.tr("Localizable", "torSetup.learn.btnIn", fallback: "Opt in")
      /// Opt out
      public static let btnOut = L10n.tr("Localizable", "torSetup.learn.btnOut", fallback: "Opt out")
      /// This beta feature provides additional protections for your IP address. If Tor is permitted in your region, we recommend enabling it. You can manage this in Advanced Settings.
      public static let desc = L10n.tr("Localizable", "torSetup.learn.desc", fallback: "This beta feature provides additional protections for your IP address. If Tor is permitted in your region, we recommend enabling it. You can manage this in Advanced Settings.")
    }
    public enum Option1 {
      /// Fetch exchange rates from third-party servers without revealing your IP address. (Only available with Tor enabled.)
      public static let desc = L10n.tr("Localizable", "torSetup.option1.desc", fallback: "Fetch exchange rates from third-party servers without revealing your IP address. (Only available with Tor enabled.)")
      /// Currency Conversion
      public static let title = L10n.tr("Localizable", "torSetup.option1.title", fallback: "Currency Conversion")
    }
    public enum Option2 {
      /// Send and retrieve transaction data over Tor for added privacy.
      public static let desc = L10n.tr("Localizable", "torSetup.option2.desc", fallback: "Send and retrieve transaction data over Tor for added privacy.")
      /// Transactions
      public static let title = L10n.tr("Localizable", "torSetup.option2.title", fallback: "Transactions")
    }
    public enum Option3 {
      /// Access third-party APIs (e.g. NEAR) over Tor for added privacy.
      public static let desc = L10n.tr("Localizable", "torSetup.option3.desc", fallback: "Access third-party APIs (e.g. NEAR) over Tor for added privacy.")
      /// Integrations
      public static let title = L10n.tr("Localizable", "torSetup.option3.title", fallback: "Integrations")
    }
    public enum Settings {
      /// Tor provides additional protections for your IP address. This feature uses Tor network to fetch exchange rates, send transactions, retrieve transaction data, and connect to third party APIs.
      public static let desc1 = L10n.tr("Localizable", "torSetup.settings.desc1", fallback: "Tor provides additional protections for your IP address. This feature uses Tor network to fetch exchange rates, send transactions, retrieve transaction data, and connect to third party APIs.")
      /// As a beta feature, it may affect performance. If Tor is permitted in your region, we recommend enabling it.
      public static let desc2 = L10n.tr("Localizable", "torSetup.settings.desc2", fallback: "As a beta feature, it may affect performance. If Tor is permitted in your region, we recommend enabling it.")
    }
  }
  public enum Transaction {
    /// Receive failed
    public static let failedReceive = L10n.tr("Localizable", "transaction.failedReceive", fallback: "Receive failed")
    /// Send failed
    public static let failedSend = L10n.tr("Localizable", "transaction.failedSend", fallback: "Send failed")
    /// Shielding Failed
    public static let failedShieldedFunds = L10n.tr("Localizable", "transaction.failedShieldedFunds", fallback: "Shielding Failed")
    /// Received
    public static let received = L10n.tr("Localizable", "transaction.received", fallback: "Received")
    /// Receiving
    public static let receiving = L10n.tr("Localizable", "transaction.receiving", fallback: "Receiving")
    /// Save address
    public static let saveAddress = L10n.tr("Localizable", "transaction.saveAddress", fallback: "Save address")
    /// Select text
    public static let selectText = L10n.tr("Localizable", "transaction.selectText", fallback: "Select text")
    /// Sending
    public static let sending = L10n.tr("Localizable", "transaction.sending", fallback: "Sending")
    /// Sent
    public static let sent = L10n.tr("Localizable", "transaction.sent", fallback: "Sent")
    /// Shielded
    public static let shieldedFunds = L10n.tr("Localizable", "transaction.shieldedFunds", fallback: "Shielded")
    /// Shielding
    public static let shieldingFunds = L10n.tr("Localizable", "transaction.shieldingFunds", fallback: "Shielding")
  }
  public enum TransactionHistory {
    /// Address
    public static let address = L10n.tr("Localizable", "transactionHistory.address", fallback: "Address")
    /// Completed
    public static let completed = L10n.tr("Localizable", "transactionHistory.completed", fallback: "Completed")
    /// 0.001
    public static let defaultFee = L10n.tr("Localizable", "transactionHistory.defaultFee", fallback: "0.001")
    /// Transaction Details
    public static let details = L10n.tr("Localizable", "transactionHistory.details", fallback: "Transaction Details")
    /// Get some ZEC
    public static let getSomeZec = L10n.tr("Localizable", "transactionHistory.getSomeZec", fallback: "Get some ZEC")
    /// Make the first move...
    public static let makeTransaction = L10n.tr("Localizable", "transactionHistory.makeTransaction", fallback: "Make the first move...")
    /// No Message
    public static let noMessage = L10n.tr("Localizable", "transactionHistory.noMessage", fallback: "No Message")
    /// There’s nothing here, yet.
    public static let nothingHere = L10n.tr("Localizable", "transactionHistory.nothingHere", fallback: "There’s nothing here, yet.")
    /// Pending
    public static let pending = L10n.tr("Localizable", "transactionHistory.pending", fallback: "Pending")
    /// Save address
    public static let saveAddress = L10n.tr("Localizable", "transactionHistory.saveAddress", fallback: "Save address")
    /// See all
    public static let seeAll = L10n.tr("Localizable", "transactionHistory.seeAll", fallback: "See all")
    /// Send again
    public static let sendAgain = L10n.tr("Localizable", "transactionHistory.sendAgain", fallback: "Send again")
    /// Sent to
    public static let sentTo = L10n.tr("Localizable", "transactionHistory.sentTo", fallback: "Sent to")
    /// Status
    public static let status = L10n.tr("Localizable", "transactionHistory.status", fallback: "Status")
    /// %@...
    public static func threeDots(_ p1: Any) -> String {
      return L10n.tr("Localizable", "transactionHistory.threeDots", String(describing: p1), fallback: "%@...")
    }
    /// Timestamp
    public static let timestamp = L10n.tr("Localizable", "transactionHistory.timestamp", fallback: "Timestamp")
    /// Transactions
    public static let title = L10n.tr("Localizable", "transactionHistory.title", fallback: "Transactions")
    /// View less
    public static let viewLess = L10n.tr("Localizable", "transactionHistory.viewLess", fallback: "View less")
    /// View more
    public static let viewMore = L10n.tr("Localizable", "transactionHistory.viewMore", fallback: "View more")
  }
  public enum TransactionList {
    /// Collapse transaction
    public static let collapse = L10n.tr("Localizable", "transactionList.collapse", fallback: "Collapse transaction")
    /// Message
    public static let messageTitle = L10n.tr("Localizable", "transactionList.messageTitle", fallback: "Message")
    /// Messages
    public static let messageTitlePlural = L10n.tr("Localizable", "transactionList.messageTitlePlural", fallback: "Messages")
    /// No message included in transaction
    public static let noMessageIncluded = L10n.tr("Localizable", "transactionList.noMessageIncluded", fallback: "No message included in transaction")
    /// No transaction history
    public static let noTransactions = L10n.tr("Localizable", "transactionList.noTransactions", fallback: "No transaction history")
    /// Transaction Fee
    public static let transactionFee = L10n.tr("Localizable", "transactionList.transactionFee", fallback: "Transaction Fee")
    /// Transaction ID
    public static let transactionId = L10n.tr("Localizable", "transactionList.transactionId", fallback: "Transaction ID")
  }
  public enum WalletStatus {
    /// DISCONNECTED…
    public static let disconnected = L10n.tr("Localizable", "walletStatus.disconnected", fallback: "DISCONNECTED…")
    /// RESTORING YOUR WALLET…
    public static let restoringWallet = L10n.tr("Localizable", "walletStatus.restoringWallet", fallback: "RESTORING YOUR WALLET…")
  }
  public enum WhatsNew {
    /// Zodl Version %@
    public static func version(_ p1: Any) -> String {
      return L10n.tr("Localizable", "whatsNew.version", String(describing: p1), fallback: "Zodl Version %@")
    }
  }
  public enum ZecKeyboard {
    /// This transaction amount is invalid.
    public static let invalid = L10n.tr("Localizable", "zecKeyboard.invalid", fallback: "This transaction amount is invalid.")
  }
}
// swiftlint:enable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:enable nesting type_body_length type_name vertical_whitespace_opening_braces

// MARK: - Implementation Details

extension L10n {
  private static func tr(_ table: String, _ key: String, _ args: CVarArg..., fallback value: String) -> String {
    let format = BundleToken.bundle.localizedString(forKey: key, value: value, table: table)
    return String(format: format, locale: Locale.current, arguments: args)
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
