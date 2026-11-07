import AppKit

final class ClipAdjustmentView: NSView, NSTextFieldDelegate {
    let startField = NSTextField(string: "")
    let endField = NSTextField(string: "")
    let startStepper = NSStepper()
    let endStepper = NSStepper()
    let focus = NSSegmentedControl(labels: [L("起点"), L("终点")], trackingMode: .selectOne, target: nil, action: nil)
    let zoom = ClipZoomView(frame: .zero)
    let status = NSTextField(wrappingLabelWithString: "")
    private(set) var range: ClipRange
    private let duration: Double
    private var defaultStatus = ""
    private let onAdjust: (ClipSelection.Endpoint, Double) -> ClipRange?
    init(range: ClipRange, duration: Double, fps: Double?, onAdjust: @escaping (ClipSelection.Endpoint, Double) -> ClipRange?) {
        self.range = range; self.duration = duration; self.onAdjust = onAdjust
        super.init(frame: NSRect(x: 0, y: 0, width: 350, height: 280))
        wantsLayer = true; layer?.backgroundColor = Theme.bg1.cgColor
        let title = NSTextField(labelWithString: L("微调片段")); title.font = Theme.display(16, .bold); title.textColor = Theme.textPrimary
        let hint = NSTextField(wrappingLabelWithString: L("输入时间或拖动局部放大条；两个端点不会交叉。"))
        hint.font = Theme.display(11); hint.textColor = Theme.textSecondary
        var rowViews: [NSView] = []
        for (index, tuple) in [(L("起点"), startField, startStepper), (L("终点"), endField, endStepper)].enumerated() {
            let (name, field, stepper) = tuple
            let label = NSTextField(labelWithString: name); label.font = Theme.display(12); label.textColor = Theme.textSecondary
            label.widthAnchor.constraint(equalToConstant: 36).isActive = true
            field.tag = index; field.delegate = self; field.target = self; field.action = #selector(commit(_:))
            field.font = Theme.digits(12, .medium); field.setAccessibilityLabel(name)
            field.widthAnchor.constraint(equalToConstant: 150).isActive = true
            stepper.tag = index; stepper.target = self; stepper.action = #selector(step(_:))
            stepper.increment = ClipAdjustment.step(fps: fps); stepper.valueWraps = false
            stepper.setAccessibilityLabel(L("微调%@", name))
            let row = NSStackView(views: [label, field, stepper]); row.spacing = 8
            rowViews.append(row)
        }
        focus.selectedSegment = 0; focus.target = self; focus.action = #selector(focusChanged(_:))
        zoom.heightAnchor.constraint(equalToConstant: 58).isActive = true
        zoom.widthAnchor.constraint(equalToConstant: 310).isActive = true
        zoom.onChange = { [weak self] time in self?.apply(time, endpoint: self?.focus.selectedSegment == 1 ? .end : .start) }
        status.font = Theme.display(10); status.textColor = Theme.textSecondary
        status.stringValue = L("步长：%@ 秒（按标称帧率；未知时为 0.01 秒）", String(format: "%.4f", ClipAdjustment.step(fps: fps)))
        let stack = NSStackView(views: [title, hint] + rowViews + [focus, zoom, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        hint.widthAnchor.constraint(equalToConstant: 310).isActive = true
        status.widthAnchor.constraint(equalToConstant: 310).isActive = true
        defaultStatus = status.stringValue
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
        sync()
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    private func sync() {
        startField.stringValue = ClipAdjustment.text(range.start); endField.stringValue = ClipAdjustment.text(range.end)
        startStepper.minValue = 0; startStepper.maxValue = max(0, range.end - ClipSelection.minLength); startStepper.doubleValue = range.start
        endStepper.minValue = range.start + ClipSelection.minLength; endStepper.maxValue = duration; endStepper.doubleValue = range.end
        zoom.update(time: focus.selectedSegment == 1 ? range.end : range.start, duration: duration)
    }
    private func apply(_ time: Double, endpoint: ClipSelection.Endpoint) {
        guard let updated = onAdjust(endpoint, time) else { sync(); return }
        range = updated; status.stringValue = defaultStatus; sync()
    }
    @objc func commit(_ sender: NSTextField) {
        // The field shows milliseconds; re-reading unchanged text would round a frame-stepped endpoint.
        if sender.stringValue == ClipAdjustment.text(sender.tag == 1 ? range.end : range.start) { status.stringValue = defaultStatus; return }
        guard let time = TimeFormatting.parse(sender.stringValue) else { status.stringValue = L("请输入有效时间，例如 1:05.250"); return }
        apply(time, endpoint: sender.tag == 1 ? .end : .start)
    }
    @objc private func step(_ sender: NSStepper) {
        focus.selectedSegment = sender.tag
        apply(sender.doubleValue, endpoint: sender.tag == 1 ? .end : .start)
    }
    @objc private func focusChanged(_ sender: Any?) { sync() }
    func controlTextDidBeginEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField { focus.selectedSegment = field.tag; zoom.update(time: field.tag == 1 ? range.end : range.start, duration: duration) }
    }
    func controlTextDidEndEditing(_ obj: Notification) { if let field = obj.object as? NSTextField { commit(field) } }
}

final class ClipZoomView: NSView {
    var onChange: ((Double) -> Void)?
    private var detailWindow = ClipZoomWindow(center: 0, duration: 0)
    private var time = 0.0
    private var duration = 0.0
    private var dragging = false
    override var isFlipped: Bool { true }
    func update(time: Double, duration: Double) {
        self.time = time; self.duration = duration
        if !dragging { detailWindow = ClipZoomWindow(center: time, duration: duration) }
        needsDisplay = true
        setAccessibilityLabel(L("片段局部放大"))
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.bg2.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let width = max(1, bounds.width - 20), span = detailWindow.upper - detailWindow.lower
        guard span > 0 else { return }
        let line = NSBezierPath(); line.move(to: NSPoint(x: 10, y: 28)); line.line(to: NSPoint(x: bounds.width - 10, y: 28))
        Theme.textSecondary.setStroke(); line.stroke()
        for second in stride(from: ceil(detailWindow.lower), through: detailWindow.upper, by: 1) {
            let x = 10 + CGFloat((second - detailWindow.lower) / span) * width
            let text = NSAttributedString(string: TimeFormatting.string(second), attributes: [.font: Theme.digits(9, .medium), .foregroundColor: Theme.textSecondary])
            text.draw(at: NSPoint(x: x - text.size().width / 2, y: 40))
        }
        let x = 10 + CGFloat(max(0, min(1, (time - detailWindow.lower) / span))) * width
        Theme.accent2.setFill(); NSRect(x: x - 2, y: 12, width: 4, height: 28).fill()
    }
    private func move(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        onChange?(detailWindow.time(fraction: Double((x - 10) / max(1, bounds.width - 20))))
    }
    override func mouseDown(with event: NSEvent) { dragging = true; move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func mouseUp(with event: NSEvent) { move(event); dragging = false; update(time: time, duration: duration) }
}
