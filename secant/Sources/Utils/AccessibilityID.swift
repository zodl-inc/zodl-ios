// Accessibility identifiers used by Maestro / XCUITest to locate UI elements.
// Keep the string values stable — they are referenced by name in zodl-qa
// Maestro flows.

enum AccessibilityID {
    enum Navigation {
        static let back = "navigation.back"
    }

    enum Onboarding {
        static let createWallet = "onboarding.createWallet"
        static let restoreWallet = "onboarding.restoreWallet"
    }

    enum Home {
        static let receiveButton = "home.receiveButton"
        static let sendButton = "home.sendButton"
        static let payButton = "home.payButton"
        static let swapButton = "home.swapButton"
        static let moreButton = "home.moreButton"
        static let totalBalanceButton = "home.totalBalanceButton"
    }

    enum MoreSheet {
        static let moreInMore = "moreSheet.moreInMore"
    }

    enum Settings {
        static let addressBook = "settings.addressBook"
    }

    enum SendForm {
        static let addToContactsButton = "sendForm.addToContactsButton"
        static let scanButton = "sendForm.scanButton"
        static let reviewButton = "sendForm.reviewButton"
        static let zcashAddressField = "sendForm.zcashAddressField"
    }

    enum SendConfirmation {
        static let sendButton = "sendConfirmation.sendButton"
    }

    enum SwapAndPayForm {
        static let addToContactsButton = "swapAndPayForm.addToContactsButton"
        static let scanButton = "swapAndPayForm.scanButton"
    }

    enum CrossPayForm {
        static let assetSelectButton = "crossPayForm.assetSelectButton"
        static let reviewButton = "crossPayForm.reviewButton"
    }

    enum SwapForm {
        static let assetSelectButton = "swapForm.assetSelectButton"
        static let changeModeButton = "swapForm.changeModeButton"
        static let reviewButton = "swapForm.reviewButton"
    }

    enum AddressBook {
        static let addContact = "addressBook.addContact"
        static let scanEntry = "addressBook.scanEntry"
        static let manualEntry = "addressBook.manualEntry"
    }

    enum AddressBookContact {
        static let walletAddressField = "addressBookContact.walletAddressField"
        static let contactNameField = "addressBookContact.contactNameField"
        static let chainSelector = "addressBookContact.chainSelector"
        static let saveButton = "addressBookContact.saveButton"
        static let deleteButton = "addressBookContact.deleteButton"
    }

    enum RecoveryPhrase {
        static let confirmButton = "recoveryPhrase.confirmButton"
    }
}
