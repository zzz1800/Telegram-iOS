import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import SearchUI
import ItemListUI

// TGTranslate: 面板里循环切换用的取值表（只用 ActionSheet 现有组件，不引入新 UI）
private let tgTranslateTargetLanguageCycle: [String] = ["zh", "en", "ja", "ko", "fr", "ru", "es"]
private let tgTranslateOutgoingTargetCycle: [String] = ["en", "ja", "ko", "ru", "fr", "es", "zh"]
private let tgTranslateProxyCycle: [String] = ["", "http://127.0.0.1:7890", "socks5://127.0.0.1:1080"]

private func tgTranslateNextInCycle(_ list: [String], current: String) -> String {
    if let index = list.firstIndex(of: current), index + 1 < list.count {
        return list[index + 1]
    }
    return list.first ?? ""
}

public enum LocalizationListEntryTag: ItemListItemTag, Equatable {
    case showButton
    case translateChats

    public func isEqual(to other: ItemListItemTag) -> Bool {
        if let other = other as? LocalizationListEntryTag, self == other {
            return true
        } else {
            return false
        }
    }
}

public class LocalizationListController: ViewController {
    private let context: AccountContext
    private let focusOnItemTag: LocalizationListEntryTag?
    
    private var controllerNode: LocalizationListControllerNode {
        return self.displayNode as! LocalizationListControllerNode
    }
    
    private var _ready = Promise<Bool>()
    override public var ready: Promise<Bool> {
        return self._ready
    }
    
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    
    private var editItem: UIBarButtonItem!
    private var doneItem: UIBarButtonItem!
    
    private var searchContentNode: NavigationBarSearchContentNode?
    
    private var previousContentOffset: ListViewVisibleContentOffset?
    
    private func presentTGTranslateSettings() {
        let presentationData = self.presentationData
        let settings = TranslationProviderSettingsStore.shared.load()
        let kindLabel = settings.kind.displayName
        let proxyLabel = settings.googleProxy.isEmpty ? "未设置（点一下循环切换）" : settings.googleProxy
        let keyLabel = settings.baiduKey.isEmpty ? "未设置" : "已设置"
        let incomingLabel = settings.translateIncoming ? "开" : "关"
        let outgoingLabel = settings.translateOutgoing ? "开" : "关"
        let controller = ActionSheetController(theme: ActionSheetControllerTheme(presentationData: presentationData))
        var groups: [ActionSheetItemGroup] = []
        groups.append(ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: "当前引擎：" + kindLabel + "（点击切换）", action: {
                TranslationProviderSettingsStore.shared.update { current in
                    current.kind = current.kind == .google ? .baidu : .google
                }
                controller.dismissAnimated()
            }),
        ]))
        groups.append(ActionSheetItemGroup(items: [
            ActionSheetSwitchItem(title: "接收消息自动翻译（" + incomingLabel + "）", isOn: settings.translateIncoming, action: { value in
                TranslationProviderSettingsStore.shared.update { $0.translateIncoming = value }
            }),
            ActionSheetSwitchItem(title: "发送前自动翻译（" + outgoingLabel + "）", isOn: settings.translateOutgoing, action: { value in
                TranslationProviderSettingsStore.shared.update { $0.translateOutgoing = value }
            }),
        ]))
        groups.append(ActionSheetItemGroup(items: [
            // TGTranslate: 这三行原来是 enabled: false 的只读标签，导致「点过一次切换后目标语言
            // 被冻成 json 里的值且再也改不回来」。现在都可点，点完自动关闭再弹一次以刷新显示。
            ActionSheetButtonItem(title: "目标语言：" + settings.targetLanguage + "（点击切换）", action: { [weak self] in
                TranslationProviderSettingsStore.shared.update { current in
                    current.targetLanguage = tgTranslateNextInCycle(tgTranslateTargetLanguageCycle, current: current.targetLanguage)
                }
                controller.dismissAnimated()
                self?.reloadTGTranslateSettings()
            }),
            // 出站目标语言独立于「目标语言」：收外语翻 zh、打中文翻 en 才能同时成立
            ActionSheetButtonItem(title: "发送目标语言：" + settings.outgoingTargetLanguage + "（点击切换）", action: { [weak self] in
                TranslationProviderSettingsStore.shared.update { current in
                    current.outgoingTargetLanguage = tgTranslateNextInCycle(tgTranslateOutgoingTargetCycle, current: current.outgoingTargetLanguage)
                }
                controller.dismissAnimated()
                self?.reloadTGTranslateSettings()
            }),
            ActionSheetButtonItem(title: "代理：" + proxyLabel, action: { [weak self] in
                TranslationProviderSettingsStore.shared.update { current in
                    current.googleProxy = tgTranslateNextInCycle(tgTranslateProxyCycle, current: current.googleProxy)
                }
                controller.dismissAnimated()
                self?.reloadTGTranslateSettings()
            }),
            ActionSheetButtonItem(title: "百度密钥：" + keyLabel + "（点击清除）", action: { [weak self] in
                TranslationProviderSettingsStore.shared.update { current in
                    current.baiduKey = ""
                    current.baiduAppId = ""
                }
                controller.dismissAnimated()
                self?.reloadTGTranslateSettings()
            }),
        ]))
        groups.append(ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: "恢复以配置文件为准（清空界面设置）", action: { [weak self] in
                TranslationProviderSettingsStore.shared.clearUserOverride()
                controller.dismissAnimated()
                self?.reloadTGTranslateSettings()
            }),
        ]))
        groups.append(ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: "完成", action: {
                controller.dismissAnimated()
            }),
        ]))
        controller.setItemGroups(groups)
        self.present(controller, in: .window(.root))
    }

    private func reloadTGTranslateSettings() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.presentTGTranslateSettings()
        }
    }
    
    public init(context: AccountContext, focusOnItemTag: LocalizationListEntryTag? = nil) {
        self.context = context
        self.focusOnItemTag = focusOnItemTag
        
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData, style: .glass))
        
        self.editItem = UIBarButtonItem(title: "___done", style: .done, target: self, action: #selector(self.editPressed))
        self.doneItem = UIBarButtonItem(title: self.presentationData.strings.Common_Edit, style: .plain, target: self, action: #selector(self.editPressed))
        
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        
        self.title = self.presentationData.strings.Settings_AppLanguage
        
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        
        self.scrollToTop = { [weak self] in
            if let strongSelf = self {
                if let searchContentNode = strongSelf.searchContentNode {
                    searchContentNode.updateExpansionProgress(1.0, animated: true)
                }
                strongSelf.controllerNode.scrollToTop()
            }
        }
        
        tgTranslatePresentSettings = { [weak self] in
            self?.presentTGTranslateSettings()
        }
        
        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            if let strongSelf = self {
                let previousTheme = strongSelf.presentationData.theme
                let previousStrings = strongSelf.presentationData.strings
                
                strongSelf.presentationData = presentationData
                
                if previousTheme !== presentationData.theme || previousStrings !== presentationData.strings {
                    strongSelf.updateThemeAndStrings()
                }
            }
        })
        
        self.searchContentNode = NavigationBarSearchContentNode(theme: self.presentationData.theme, placeholder: self.presentationData.strings.Common_Search, inline: true, activate: { [weak self] in
            self?.activateSearch()
        })
        self.navigationBar?.setContentNode(self.searchContentNode, animated: false)
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.presentationDataDisposable?.dispose()
    }
    
    private func updateThemeAndStrings() {
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: self.presentationData, style: .glass), transition: .immediate)
        self.searchContentNode?.updateThemeAndPlaceholder(theme: self.presentationData.theme, placeholder: self.presentationData.strings.Common_Search)
        self.title = self.presentationData.strings.Settings_AppLanguage
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        self.controllerNode.updatePresentationData(self.presentationData)
        
        let editItem = UIBarButtonItem(title: self.presentationData.strings.Common_Done, style: .done, target: self, action: #selector(self.editPressed))
        let doneItem = UIBarButtonItem(title: self.presentationData.strings.Common_Edit, style: .plain, target: self, action: #selector(self.editPressed))
        if self.navigationItem.rightBarButtonItem === self.editItem {
            self.navigationItem.rightBarButtonItem = editItem
        } else if self.navigationItem.rightBarButtonItem === self.doneItem {
            self.navigationItem.rightBarButtonItem = doneItem
        }
        self.editItem = editItem
        self.doneItem = doneItem
    }
    
    override public func loadDisplayNode() {
        self.displayNode = LocalizationListControllerNode(context: self.context, presentationData: self.presentationData, navigationBar: self.navigationBar!, requestActivateSearch: { [weak self] in
            self?.activateSearch()
        }, requestDeactivateSearch: { [weak self] in
            self?.deactivateSearch()
        }, updateCanStartEditing: { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            let item: UIBarButtonItem?
            if let value = value {
                item = value ? strongSelf.editItem : strongSelf.doneItem
            } else {
                item = nil
            }
            if strongSelf.navigationItem.rightBarButtonItem !== item {
                strongSelf.navigationItem.setRightBarButton(item, animated: true)
            }
        }, present: { [weak self] c, a in
            self?.present(c, in: .window(.root), with: a)
        }, push: { [weak self] c in
            self?.push(c)
        }, focusOnItemTag: self.focusOnItemTag)
        
        self.controllerNode.listNode.visibleContentOffsetChanged = { [weak self] offset, _ in
            if let strongSelf = self {
                if let searchContentNode = strongSelf.searchContentNode {
                    searchContentNode.updateListVisibleContentOffset(offset)
                }
                
                var previousContentOffsetValue: CGFloat?
                if let previousContentOffset = strongSelf.previousContentOffset, case let .known(value) = previousContentOffset {
                    previousContentOffsetValue = value
                }
                switch offset {
                    case let .known(value):
                        let transition: ContainedViewLayoutTransition
                        if let previousContentOffsetValue = previousContentOffsetValue, value <= 0.0, previousContentOffsetValue > 30.0 {
                            transition = .animated(duration: 0.2, curve: .easeInOut)
                        } else {
                            transition = .immediate
                        }
                        strongSelf.navigationBar?.updateBackgroundAlpha(min(30.0, max(0.0, value - 54.0)) / 30.0, transition: transition)
                    case .unknown, .none:
                        strongSelf.navigationBar?.updateBackgroundAlpha(1.0, transition: .immediate)
                }
                
                strongSelf.previousContentOffset = offset
            }
        }
        
        self.controllerNode.listNode.didEndScrolling = { [weak self] _ in
            if let strongSelf = self, let searchContentNode = strongSelf.searchContentNode {
                let _ = fixNavigationSearchableListNodeScrolling(strongSelf.controllerNode.listNode, searchNode: searchContentNode)
            }
        }
        
        self._ready.set(self.controllerNode._ready.get())
        
        self.navigationBar?.updateBackgroundAlpha(0.0, transition: .immediate)
        
        self.displayNodeDidLoad()
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.cleanNavigationHeight, transition: transition)
    }
    
    @objc private func editPressed() {
        self.controllerNode.toggleEditing()
    }
    
    private func activateSearch() {
        if self.displayNavigationBar {
            if let scrollToTop = self.scrollToTop {
                scrollToTop()
            }
            if let searchContentNode = self.searchContentNode {
                self.controllerNode.activateSearch(placeholderNode: searchContentNode.placeholderNode)
            }
            self.setDisplayNavigationBar(false, transition: .animated(duration: 0.5, curve: .spring))
        }
    }
    
    private func deactivateSearch() {
        if !self.displayNavigationBar {
            self.setDisplayNavigationBar(true, transition: .animated(duration: 0.5, curve: .spring))
            if let searchContentNode = self.searchContentNode {
                self.controllerNode.deactivateSearch(placeholderNode: searchContentNode.placeholderNode)
            }
        }
    }
}
