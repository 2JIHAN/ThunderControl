import AppKit

#if TC_QUALITY_TIERS
@MainActor extension App {
    /// Reuses the existing Settings tab and appearance view; no second window.
    func setupDisplayQualityUI(appearanceView: NSView) -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20)
        ])
        appearanceView.heightAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(appearanceView)
        appearanceView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let title = NSTextField(labelWithString: "가상 디스플레이 품질")
        title.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(title)
        displayQualityCapPicker.removeAllItems()
        for (label, tier) in [("자동: 가능한 최고 품질 (ProRes LT까지)", DisplayQualityTier.highest),
                              ("고품질 상한 (ProRes Proxy)", .high),
                              ("표준 상한 (HEVC)", .standard),
                              ("호환성 (H.264)", .compatibility)] {
            displayQualityCapPicker.addItem(withTitle: label)
            displayQualityCapPicker.lastItem?.tag = tier.rawValue
        }
        displayQualityCapPicker.target = self
        displayQualityCapPicker.action = #selector(displayQualityPreferencesChanged(_:))
        displayQualityCapPicker.setAccessibilityLabel("영상 품질 상한")
        displayQualityCapPicker.toolTip = "상한보다 낮은 코덱이 선택될 수 있습니다. 연결 중 변경은 비동기로 요청합니다."
        stack.addArrangedSubview(displayQualityCapPicker)
        displayPresentationPicker.target = self
        displayPresentationPicker.action = #selector(displayQualityPreferencesChanged(_:))
        displayPresentationPicker.setAccessibilityLabel("화면 표시 우선순위")
        stack.addArrangedSubview(displayPresentationPicker)
        func addHelp(_ text: String) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        addHelp("자동은 두 Mac이 지원하는 범위에서 더 낮은 쪽 상한을 적용합니다. ProRes LT와 Proxy는 H.264나 HEVC보다 더 많은 대역폭을 사용할 수 있습니다. 실제 화질과 지연은 기기와 화면 내용에 따라 달라집니다.")
        addHelp("반응속도 우선은 대기를 줄이고, 부드러움 우선은 짧은 프레임 대기를 허용합니다. 끊김 감소나 지연 개선을 보장하지 않습니다.")
        displayQualityActualLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(displayQualityActualLabel)
        displayQualityActualLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addHelp("설정은 저장되며 연결 중 변경은 비동기로 요청합니다. 실제 적용 상태는 현재 코덱으로 확인하세요. 연결을 재시작하지 않으며 Thunderbolt만 사용합니다.")
        refreshDisplayQualityUI()
        return container
    }

    @objc func displayQualityPreferencesChanged(_ sender: NSControl) {
        guard let tier = displayQualityCapPicker.selectedItem.flatMap({ DisplayQualityTier(rawValue: $0.tag) }),
              let presentation = DisplayPresentationMode(rawValue: displayPresentationPicker.selectedSegment) else { return }
        DisplayQualityPreferences(maximumTier: tier, presentation: presentation).save()
        // The controller owns asynchronous preparation and safe commit. The UI
        // never stops/restarts a session or changes trust/routing.
        displayMode.requestQualitySettingsUpdate()
        refreshDisplayQualityUI()
    }

    func refreshDisplayQualityUI() {
        let preferences = DisplayQualityPreferences.load()
        if displayQualityCapPicker.selectedItem?.tag != preferences.maximumTier.rawValue {displayQualityCapPicker.selectItem(withTag: preferences.maximumTier.rawValue)}
        displayPresentationPicker.selectedSegment = preferences.presentation.rawValue
        if let name = displayMode.currentDisplayCodecName,
           let tier = DisplayQualityTier(wireCodecName: name) {
            displayQualityActualLabel.stringValue = "현재 실제 코덱: \(tier.codecDisplayName)"
        } else {
            displayQualityActualLabel.stringValue = displayMode.active ? "현재 실제 코덱: 영상 프레임 확인 대기" : "현재 실제 코덱: 연결되지 않음"
        }
    }
}
#endif
