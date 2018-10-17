import Foundation
import UIKit
import Photos

public typealias TelegramSelection = (TelegramSelectionType) -> ()

public enum TelegramSelectionType {
    
    case photo([PHAsset])
    case location(Location?)
    case contact(Contact?)
    case camera(Camera.PreviewStream)
    case document
    case photosAsDocuments([PHAsset])
}

extension UIAlertController {
    
    /// Add Telegram Picker
    ///
    /// - Parameters:
    ///   - selection: type and action for selection of asset/assets
    
    public func addTelegramPicker(selection: @escaping TelegramSelection,
                                  localizer: TelegramPickerResourceProvider) {
        let vc = TelegramPickerViewController(selection: selection, localizer: localizer)
        set(vc: vc)
    }
}

extension UIImageView: DisplaceableView {}

final public class TelegramPickerViewController: UIViewController {
    
    var buttons: [ButtonType] {
        switch mode {
        case .normal: return [.photoOrVideo, .file, .location, .contact]
        case .bigPhotoPreviews: return [.sendPhotos]
        case .documentType: return [.documentAsFile, .photoAsFile]
        }
    }
    
    enum ButtonType {
        case photoOrVideo
        case location
        case contact
        case file
        case sendPhotos
        case documentAsFile
        case photoAsFile
    }
    
    enum StreamItem: Equatable {
        case photo(PHAsset)
        case video(PHAsset)
        case camera
        
        var isCamera: Bool {
            switch self {
            case .camera: return true
            default: return false
            }
        }
        
        public static func == (lhs: StreamItem, rhs: StreamItem) -> Bool {
            switch (lhs, rhs) {
            case (let .photo(lhsAsset), let .photo(rhsAsset)): return lhsAsset == rhsAsset
            case (let .video(lhsAsset), let .video(rhsAsset)): return lhsAsset == rhsAsset
            case (.camera, .camera): return true
            default: return false
            }
        }
        
        var galaryItem: GalleryItem? {
            switch self {
            case .photo(let asset):
                return GalleryItem.image(fetchImageBlock: { completion in
                    Assets.resolve(asset: asset) { image in
                        completion(image ?? UIImage())
                    } })
            case .video(let asset):
                return GalleryItem.video(fetchPreviewImageBlock:  { completion in
                    Assets.resolve(asset: asset) { image in
                        completion(image ?? UIImage())
                        }
                }, videoURL: { completion in
                    Assets.resolveVideo(asset: asset, completion: { (url) in
                        completion(url)
                    })
                })
            case .camera:
                return nil
            }
        }
    }
    
    enum CellId: String {
        case photo
        case video
        case camera
    }
    
    enum Mode: Int {
        case normal
        case bigPhotoPreviews
        case documentType
    }
    
    // MARK: UI
    
    struct UI {
        static let rowHeight: CGFloat = 58
        static let insets: UIEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        static let minimumInteritemSpacing: CGFloat = 6
        static let minimumLineSpacing: CGFloat = 6
        static let maxHeight: CGFloat = UIScreen.main.bounds.width / 2
        static let multiplier: CGFloat = 2
    }
    
    fileprivate var mode = Mode.normal
    
    private var photoLayout: PhotoLayout {
        return collectionView.collectionViewLayout as! PhotoLayout
    }
    
    func title(for button: ButtonType) -> String {
        
        let localizableButton: LocalizableButtonType
        
        switch button {
        case .photoOrVideo: localizableButton = .photoOrVideo
        case .file: localizableButton = .file
        case .location: localizableButton = .location
        case .contact: localizableButton = .contact
        case .sendPhotos: localizableButton = .photos(count: selectedAssets.count)
        case .documentAsFile: localizableButton = .sendDocumentAsFile
        case .photoAsFile: localizableButton = .sendPhotoAsFile
        }
        
        return self.localizer.localized(buttonType: localizableButton)
    }
    
    func font(for button: ButtonType) -> UIFont {
        switch button {
        case .sendPhotos: return UIFont.boldSystemFont(ofSize: 20)
        default: return UIFont.systemFont(ofSize: 20) }
    }
    
    var preferredTableHeaderHeight: CGFloat {
        switch mode {
        case .normal: return UI.maxHeight / UI.multiplier + UI.insets.top + UI.insets.bottom
        case .bigPhotoPreviews: return UI.maxHeight + UI.insets.top + UI.insets.bottom
        case .documentType: return 0
        }
    }
    
    public var cameraCellNeeded: Bool = true {
        didSet {
            if cameraCellNeeded != oldValue, isViewLoaded {
                self.layout.invalidateLayout()
            }
        }
    }
    
    public var cameraStream: Camera.PreviewStream? = nil {
        didSet {
            if cameraStream !== oldValue, isViewLoaded {
                updateCameraCells()
            }
        }
    }
    
    public var shouldShowCameraStream: Bool {
        return cameraCellNeeded && mode == .normal
    }
    
    private var visibleItemEntries: [(indexPath: IndexPath, item: StreamItem)] {
        let indexPaths = collectionView.indexPathsForVisibleItems
        let entries: [(indexPath: IndexPath, item: StreamItem)] = indexPaths.map({ (indexPath: $0, item: items[$0.item]) })
        return entries
    }
    
    func sizeForPreviewPreload(asset: PHAsset) -> CGSize {
        let height: CGFloat = UI.maxHeight
        let width: CGFloat = CGFloat(Double(height) * Double(asset.pixelWidth) / Double(asset.pixelHeight))
        return CGSize(width: width, height: height)
    }
    
    func sizeForAsset(asset: PHAsset) -> CGSize {
        switch mode {
        case .bigPhotoPreviews:
            let minValue: CGFloat = UI.maxHeight / UI.multiplier
            var size = CGSize.init(width: asset.pixelWidth, height: asset.pixelHeight)
            let multiplier = UI.maxHeight / size.height
            size.height *= multiplier
            size.width = min(minValue, size.width*multiplier)
            return size
        case .normal:
            let value: CGFloat = UI.maxHeight / UI.multiplier
            return CGSize(width: value, height: value)
        case .documentType:
            return .zero
        }
    }
    
    func sizeForItem(item: StreamItem) -> CGSize {
        switch item {
        case .camera:
            let side = UI.maxHeight / UI.multiplier
            return CGSize.init(width: side, height: side)
        case .photo(let asset), .video(let asset):
            return sizeForAsset(asset: asset)
        }
    }
    
    // MARK: Properties
    
    fileprivate lazy var collectionView: UICollectionView = { [unowned self] in
        $0.dataSource = self
        $0.delegate = self
        $0.allowsMultipleSelection = true
        $0.showsVerticalScrollIndicator = false
        $0.showsHorizontalScrollIndicator = false
        $0.decelerationRate = UIScrollViewDecelerationRateFast
        //        $0.contentInsetAdjustmentBehavior = .never
        $0.contentInset = UI.insets
        $0.backgroundColor = .clear
        $0.layer.masksToBounds = false
        $0.clipsToBounds = false
        $0.register(CollectionViewPhotoCell.self, forCellWithReuseIdentifier: CellId.photo.rawValue)
        $0.register(CollectionViewVideoCell.self, forCellWithReuseIdentifier: CellId.video.rawValue)
        $0.register(CollectionViewCameraCell.self, forCellWithReuseIdentifier: CellId.camera.rawValue)
        
        return $0
        }(UICollectionView(frame: .zero, collectionViewLayout: layout))
    
    fileprivate lazy var layout: PhotoLayout = { [unowned self] in
        $0.delegate = self
        $0.lineSpacing = UI.minimumLineSpacing
        return $0
        }(PhotoLayout())
    
    fileprivate lazy var tableView: UITableView = { [unowned self] in
        $0.dataSource = self
        $0.delegate = self
        $0.rowHeight = UI.rowHeight
        $0.separatorColor = UIColor.lightGray.withAlphaComponent(0.4)
        $0.separatorInset = .zero
        $0.backgroundColor = nil
        $0.bounces = false
        $0.tableHeaderView = collectionView
        $0.tableFooterView = UIView()
        $0.register(LikeButtonCell.self, forCellReuseIdentifier: LikeButtonCell.identifier)
        
        return $0
        }(UITableView(frame: .zero, style: .plain))
    
    lazy var items = [StreamItem]()
    lazy var selectedAssets = [PHAsset]()
    var galleryItems: [StreamItem] {
        return items.filter({ $0 != .camera })
    }
    
    let selection: TelegramSelection
    let localizer: TelegramPickerResourceProvider
    
    // MARK: Initialize
    
    required public init(selection: @escaping TelegramSelection,
                         localizer: TelegramPickerResourceProvider) {
        self.selection = selection
        self.localizer = localizer
        super.init(nibName: nil, bundle: nil)
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func loadView() {
        view = tableView
    }
    
    override public func viewDidLoad() {
        super.viewDidLoad()
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            preferredContentSize.width = UIScreen.main.bounds.width * 0.5
        }
        
        updatePhotos()
        updateCamera()
    }
    
    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        tableView.tableHeaderView?.frame.size.height = preferredTableHeaderHeight
    }
    
    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preferredContentSize.height = tableView.contentSize.height
    }
    
    func resetItems() {
        
        var newItems = items
        var hasCameraItem = false
        var itemsChanged = false
        
        if let first = newItems.first, first.isCamera {
            hasCameraItem = true
        }
        
        if shouldShowCameraStream && !hasCameraItem {
            newItems.insert(.camera, at: 0)
            itemsChanged = true
        }
        else if !shouldShowCameraStream && hasCameraItem {
            newItems.remove(at: 0)
            itemsChanged = true
        }
        
        guard itemsChanged else {
            return
        }
        
        resetItems(newItems: newItems)
    }
    
    func resetItems(assets: [PHAsset]) {
        
        var newItems = assets.compactMap({ asset -> StreamItem? in
            switch asset.mediaType {
            case .video:
                return StreamItem.video(asset)
            case .image:
                return StreamItem.photo(asset)
            default:
                return nil
            }
        })
        if shouldShowCameraStream {
            newItems.insert(.camera, at: 0)
        }
        
        resetItems(newItems: newItems)
    }
    
    func resetItems(newItems: [StreamItem]) {
        items = newItems
        tableView.reloadData()
        collectionView.reloadData()
    }
    
    func updateCamera() {
        guard cameraCellNeeded else {
            cameraStream = nil
            return
        }
        
        checkCameraState { [weak self] (stream) in
            self?.cameraStream = stream
        }
    }
    
    func updatePhotos() {
        checkStatus { [weak self] assets in
            self?.resetItems(assets: assets)
        }
    }
    
    func setupCameraStream(_ completionHandler: @escaping (Camera.PreviewStream?) -> ()) {
        Camera.PreviewStream.create { (result) in
            DispatchQueue.main.async {
                switch result {
                case .error(error: let error):
                    self.handleCameraStreamFailure(error)
                    completionHandler(nil)
                case .stream(let stream):
                    completionHandler(stream)
                }
            }
        }
    }
    
    func handleCameraStreamFailure(_ error: Error) {
        print("Error while setup camera stream. \(error.localizedDescription)")
        if let alert = localizer.localizedAlert(failure: .error(error)) {
            alert.show()
        }
    }
    
    func checkCameraState(completionHandler: @escaping (Camera.PreviewStream?)->()) {
        
        /// This case means the user is prompted for the first time for camera access
        switch Camera.authorizationStatus {
        case .notDetermined:
            Camera.requestAccess { [weak self] (_) in
                self?.checkCameraState(completionHandler: completionHandler)
            }
        case .authorized:
            setupCameraStream(completionHandler)
            
        case .denied, .restricted:
            /// User has denied the current app to access the camera.
            let productName = Bundle.main.dlgpicker_appName
            let alert = UIAlertController(style: .alert, title: "Permission denied", message: "\(productName) does not have access to camera. Please, allow the application to access to camera.")
            alert.addAction(title: "Settings", style: .destructive) { action in
                if let settingsURL = URL(string: UIApplicationOpenSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            }
            alert.addAction(title: "OK", style: .cancel) { [unowned self] action in
                self.alertController?.dismiss(animated: true)
            }
            alert.show()
        }
    }
    
    func checkStatus(completionHandler: @escaping ([PHAsset]) -> ()) {
        Log("status = \(PHPhotoLibrary.authorizationStatus())")
        switch PHPhotoLibrary.authorizationStatus() {
            
        case .notDetermined:
            /// This case means the user is prompted for the first time for allowing contacts
            Assets.requestAccess { [unowned self] status in
                self.checkStatus(completionHandler: completionHandler)
            }
            
        case .authorized:
            /// Authorization granted by user for this app.
            DispatchQueue.main.async {
                self.fetchPhotos(completionHandler: completionHandler)
            }
            
        case .denied, .restricted:
            /// User has denied the current app to access the contacts.
            
            if let alert = localizer.localizedAlert(failure: .noAccessToPhoto) {
                alert.show()
            }
        }
    }
    
    func fetchPhotos(completionHandler: @escaping ([PHAsset]) -> ()) {
        Assets.fetch { [weak self] result in
            switch result {
                
            case .success(let assets):
                completionHandler(assets)
                
            case .error(let error):
                if let alert = self?.localizer.localizedAlert(failure: .error(error)) {
                    alert.show()
                }
            }
        }
    }
    
    func action(withItem item: StreamItem, at indexPath: IndexPath) {
        switch item {
        case .camera:
            if let stream = cameraStream {
                selection(.camera(stream))
            }
        case .photo(let asset), .video(let asset):
//            action(withAsset: asset, at: indexPath)
            openPreview(with: asset, at: indexPath)
        }
    }
    
    func action(withAsset asset: PHAsset, at indexPath: IndexPath) {
        guard mode != .documentType else {
            return
        }
        
        selectedAssets.contains(asset) ? selectedAssets.remove(asset) : selectedAssets.append(asset)
        
        let oldMode = mode
        let newMode: Mode = selectedAssets.isEmpty ? .normal : .bigPhotoPreviews
        
        if mode != newMode {
            applyMode(newMode)
        } else {
            updateSendButtonsTitleIfNeeded()
        }
        
        //Reload all visible cells because need to update selection index
        updateVisibleSelectionIndexes()
        
        let scrollAnimated = oldMode == newMode
        collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: scrollAnimated)
    }
    
    func openPreview(with asset: PHAsset, at indexPath: IndexPath) {
        let galleryItemIndex = galleryItems.index(of: items[indexPath.item]) ?? 0
        let galleryViewController = GalleryViewController(startIndex: galleryItemIndex,
                                                          itemsDataSource: self,
                                                          itemsDelegate: self,
                                                          displacedViewsDataSource: self,
                                                          configuration: galleryConfiguration())
        galleryViewController.selectionCompletion = { [weak self] button in
            //TODO: check for galleryViewController asset is in selected
            guard let item = self?.galleryItems[galleryViewController.currentIndex] else { return }
            
            switch item {
            case .photo(let asset), .video(let asset):
                if self?.selectedAssets.contains(asset) == true {
                    self?.selectedAssets.remove(asset)
                    button.isSelected = false
                } else {
                    self?.selectedAssets.append(asset)
                    button.setTitle(String(self?.selectedAssets.count ?? 1), for: .selected)
                    button.isSelected = true
                }
            default:
                break
            }
            self?.updateVisibleSelectionIndexes()
        }
        present(galleryViewController, animated: false, completion: nil)
    }
    
    func updateVisibleSelectionIndexes() {
        let visibleCells = collectionView.visibleCells.compactMap({ $0 as? CollectionViewCustomContentCell<UIImageView> })
        for visibleCell in visibleCells {
            if let indexPath = collectionView.indexPath(for: visibleCell) {
                let item = items[indexPath.item]
                switch item {
                case .photo(let _asset), .video(let _asset):
                    if let indexForUpdate = selectedAssets.index(of: _asset) {
                        visibleCell.updateSelectionIndex(indexForUpdate + 1)
                    }
                default:()
                }
            }
        }
    }
    
    func updateSendButtonsTitleIfNeeded() {
        if let idx = buttons.index(of: .sendPhotos),
            let cell = tableView.cellForRow(at: IndexPath(row: idx, section: 0)) as? LikeButtonCell {
            let title = self.localizer.localized(buttonType: .photos(count: self.selectedAssets.count))
            cell.textLabel?.text = title
        }
    }
    
    func applyMode(_ newMode: Mode) {
        
        guard newMode != self.mode else {
            return
        }
        
        mode = newMode
        
        collectionView.isHidden = newMode == .documentType
        
        switch mode {
        case .documentType:
            tableView.reloadData()
        case .bigPhotoPreviews:
            tableView.reloadData()
        case .normal:
            tableView.reloadSections([0], with: .fade)
        }
        
        //        collectionView.performBatchUpdates({
        self.layout.mode = (newMode == .normal) ? .normal : .hidingFirstItem
        //        })
        
    }
    
    func switchToDocumentTypeMenu() {
        self.applyMode(.documentType)
    }
    
    func action(for button: ButtonType) {
        switch button {
            
        case .photoOrVideo:
            let selection = self.selection
            alertController?.addPhotoLibraryPicker(flow: .vertical, paging: false, selection: .multiple(action: { assets in
                selection(TelegramSelectionType.photo(assets))
            }))
            
        case .photoAsFile:
            let selection = self.selection
            alertController?.addPhotoLibraryPicker(flow: .vertical, paging: false, selection: .multiple(action: { assets in
                selection(TelegramSelectionType.photosAsDocuments(assets))
            }))
            
        case .documentAsFile:
            let selection = self.selection
            alertController?.dismiss(animated: true) {
                selection(.document)
            }
            
        case .location:
            let selection = self.selection
            let provider = self.localizer.resourceProviderForLocationPicker()
            alertController?.addLocationPicker(location: nil,
                                               resourceProvider: provider,
                                               completion: { location in
                                                selection(TelegramSelectionType.location(location))
            })
            
        case .contact:
            let selection = self.selection
            alertController?.addContactsPicker { contact in
                selection(TelegramSelectionType.contact(contact))
            }
            
        case .sendPhotos:
            let assets = selectedAssets
            let selection = self.selection
            alertController?.dismiss(animated: true) {
                selection(TelegramSelectionType.photo(assets))
            }
            
        case .file:
            self.switchToDocumentTypeMenu()
        }
    }
}

// MARK: - TableViewDelegate

extension TelegramPickerViewController: UICollectionViewDelegate {
    
    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if isSelectableItem(at: indexPath, collectionView: collectionView) {
            layout.selectedCellIndexPath = indexPath
        }
        action(withItem: items[indexPath.item], at: indexPath)
    }
    
    public func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        layout.selectedCellIndexPath = nil
        action(withItem: items[indexPath.item], at: indexPath)
    }
    
    private func isSelectableItem(at indexPath: IndexPath, collectionView: UICollectionView) -> Bool {
        switch items[indexPath.item] {
        case .camera:
            return false
        case .photo(_), .video(_):
            return true
        }
    }
    
}

// MARK: - CollectionViewDataSource

extension TelegramPickerViewController: UICollectionViewDataSource {
    
    public func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }
    
    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }
    
    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        
        switch items[indexPath.item] {
        case .camera:
            return dequeue(collectionView, cellForCameraAt: indexPath)
            
        case .photo(let asset), .video(let asset):
            return dequeue(collectionView, cellForAsset: asset, at: indexPath)
        }
        
    }
    
    private func dequeue(_ collectionView: UICollectionView, cellForCameraAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell: CollectionViewCameraCell = dequeue(collectionView, id: .camera, indexPath: indexPath)
        cell.showSelectionCircles = false
        return cell
    }
    
    private func dequeue(_ collectionView: UICollectionView,
                         cellForAsset asset: PHAsset,
                         at indexPath: IndexPath) -> UICollectionViewCell {
        var cell: CollectionViewCustomContentCell<UIImageView>!
        switch asset.mediaType {
        case .video:
            cell = dequeue(collectionView, id: .video, indexPath: indexPath)
        default:
            cell = dequeue(collectionView, id: .photo, indexPath: indexPath)
        }
        cell.customContentView.image = nil
        return cell
    }
    
    private func dequeue<CellClass>(_ collectionView: UICollectionView, id: CellId, indexPath: IndexPath) -> CellClass {
        return collectionView.dequeueReusableCell(withReuseIdentifier: id.rawValue, for: indexPath) as! CellClass
    }
    
    public func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        
        switch items[indexPath.item] {
        //TODO: Add Cell for video
        case .photo(let asset):
            guard let photoCell = cell as? CollectionViewPhotoCell else {
                return
            }
            
            let size = sizeForPreviewPreload(asset: asset)
            DispatchQueue.main.async {
                // We must sure that cell still visible and represents same asset
                Assets.resolve(asset: asset, size: size) { [weak self] new in
                    self?.updatePhoto(new, asset: asset)
                    photoCell.customContentView.image = new
                    
                    if let index = self?.selectedAssets.index(of: asset) {
                        photoCell.updateSelectionIndex(index + 1)
                    }
                }
            }
        case .video(let asset):
            guard let videoCell = cell as? CollectionViewVideoCell else {
                return
            }
            
            let size = sizeForPreviewPreload(asset: asset)
            DispatchQueue.main.async {
                // We must sure that cell still visible and represents same asset
                Assets.resolve(asset: asset, size: size) { [weak self] new in
                    self?.updatePhoto(new, asset: asset)
                    videoCell.customContentView.image = new
                    videoCell.updateVideo(duration: asset.duration)
                    
                    if let index = self?.selectedAssets.index(of: asset) {
                        videoCell.updateSelectionIndex(index + 1)
                    }
                }
            }
            
        case .camera:
            guard let cameraCell = cell as? CollectionViewCameraCell else {
                return
            }
            
            cameraCell.customContentView.representedStream = self.cameraStream
        }
        
        self.updateVisibleAreaRect(cell: cell, indexPath: indexPath)
    }
    
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else {
            return
        }
        
        updateVisibleCellsVisibleAreaRects()
    }
    
    private func updateVisibleCellsVisibleAreaRects() {
        let indexPaths = collectionView.indexPathsForVisibleItems
        for indexPath in indexPaths {
            if let cell = collectionView.cellForItem(at: indexPath) {
                updateVisibleAreaRect(cell: cell, indexPath: indexPath)
            }
        }
    }
    
    private func updateVisibleAreaRect(cell: UICollectionViewCell, indexPath: IndexPath) {
        guard let cell = cell as? CollectionViewPhotoCell else {
            return
        }
        
        let cellVisibleRectInCollectionView = cell.convert(cell.bounds, to: collectionView)
        let cellVisibleAreaInCollectionView = cellVisibleRectInCollectionView.intersection(collectionView.bounds)
        let cellVisibleRect = cell.convert(cellVisibleAreaInCollectionView, from: collectionView)
        
        layout.updateVisibleArea(cellVisibleRect, itemAt: indexPath, cell: cell)
    }
    
    private func updatePhoto(_ photo: UIImage?, asset: PHAsset) {
        for entry in visibleItemEntries {
            switch entry.item {
            case .photo(let itemAsset):
                if asset == itemAsset, let cell = collectionView.cellForItem(at: entry.indexPath) as? CollectionViewPhotoCell {
                    cell.customContentView.image = photo
                }
            default:
                continue
            }
        }
    }
    
    private func updateCameraCells() {
        for entry in visibleItemEntries where entry.item.isCamera {
            guard let cell = collectionView.cellForItem(at: entry.indexPath) as? CollectionViewCameraCell else {
                return
            }
            cell.customContentView.representedStream = cameraStream
        }
    }
    
}

// MARK: - PhotoLayoutDelegate

extension TelegramPickerViewController: PhotoLayoutDelegate {
    
    func collectionView(_ collectionView: UICollectionView, sizeForItemAtIndexPath indexPath: IndexPath) -> CGSize {
        return sizeForItem(item: items[indexPath.item])
    }
}

// MARK: - TableViewDelegate

extension TelegramPickerViewController: UITableViewDelegate {
    
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        self.action(for: self.buttons[indexPath.row])
    }
}

// MARK: - TableViewDataSource

extension TelegramPickerViewController: UITableViewDataSource {
    public func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return buttons.count
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LikeButtonCell.identifier) as! LikeButtonCell
        cell.textLabel?.font = font(for: buttons[indexPath.row])
        cell.textLabel?.text = title(for: buttons[indexPath.row])
        return cell
    }
}

//MARK: - GalleryItemsDataSource

extension TelegramPickerViewController: GalleryItemsDataSource {
    
    public func itemCount() -> Int {
        return galleryItems.count
    }
    
    public func provideGalleryItem(_ index: Int) -> GalleryItem {
        return galleryItems[index].galaryItem ?? GalleryItem.image(fetchImageBlock: { $0(UIImage()) })
    }
    
}

//MARK: - GalleryItemsDelegate

extension TelegramPickerViewController: GalleryItemsDelegate {
    
    public func isItemSelected(at index: Int) -> Bool {
        guard let item = galleryItems.item(at: index) else { return false }
        switch item {
        case .photo(let asset), .video(let asset):
            return selectedAssets.contains(asset)
        default:
            return false
        }
    }
    
    public func itemSelectionIndex(at index: Int) -> Int? {
        guard let item = galleryItems.item(at: index) else { return nil }
        switch item {
        case .photo(let asset), .video(let asset):
            if let selectionIndex = selectedAssets.index(of: asset) {
                return selectionIndex + 1
            } else {
                return nil
            }
        default:
            return nil
        }
    }
    
    public func removeGalleryItem(at index: Int) {
        
    }
    
}

//MARK: - GalleryDisplacedViewsDataSource

extension TelegramPickerViewController: GalleryDisplacedViewsDataSource {
    
    public func provideDisplacementItem(atIndex index: Int) -> DisplaceableView? {
        let item = galleryItems[index]
        let indexPath = IndexPath(item: items.index(of: item) ?? 0, section: 0)
        let cell = collectionView.cellForItem(at: indexPath) as? CollectionViewCustomContentCell<UIImageView>
        return cell?.customContentView
    }
    
}

private extension TelegramPickerViewController {
    
    func galleryConfiguration() -> GalleryConfiguration {
        return [
            GalleryConfigurationItem.closeButtonMode(.builtIn),
            
            GalleryConfigurationItem.pagingMode(.standard),
            GalleryConfigurationItem.presentationStyle(.displacement),
            GalleryConfigurationItem.hideDecorationViewsOnLaunch(false),
            
            GalleryConfigurationItem.swipeToDismissMode(.vertical),
            GalleryConfigurationItem.toggleDecorationViewsBySingleTap(false),
            GalleryConfigurationItem.activityViewByLongPress(false),
            
            GalleryConfigurationItem.overlayColor(UIColor(white: 0.035, alpha: 1)),
            GalleryConfigurationItem.overlayColorOpacity(1),
            GalleryConfigurationItem.overlayBlurOpacity(1),
            GalleryConfigurationItem.overlayBlurStyle(UIBlurEffectStyle.light),
            
            GalleryConfigurationItem.videoControlsColor(.white),
            
            GalleryConfigurationItem.maximumZoomScale(8),
            GalleryConfigurationItem.swipeToDismissThresholdVelocity(500),
            
            GalleryConfigurationItem.doubleTapToZoomDuration(0.15),
            
            GalleryConfigurationItem.blurPresentDuration(0.5),
            GalleryConfigurationItem.blurPresentDelay(0),
            GalleryConfigurationItem.colorPresentDuration(0.25),
            GalleryConfigurationItem.colorPresentDelay(0),
            
            GalleryConfigurationItem.blurDismissDuration(0.1),
            GalleryConfigurationItem.blurDismissDelay(0.4),
            GalleryConfigurationItem.colorDismissDuration(0.45),
            GalleryConfigurationItem.colorDismissDelay(0),
            
            GalleryConfigurationItem.itemFadeDuration(0.3),
            GalleryConfigurationItem.decorationViewsFadeDuration(0.15),
            GalleryConfigurationItem.rotationDuration(0.15),
            
            GalleryConfigurationItem.displacementDuration(0.55),
            GalleryConfigurationItem.reverseDisplacementDuration(0.25),
            GalleryConfigurationItem.displacementTransitionStyle(.springBounce(0.7)),
            GalleryConfigurationItem.displacementTimingCurve(.linear),
            
            GalleryConfigurationItem.statusBarHidden(true),
            GalleryConfigurationItem.displacementKeepOriginalInPlace(false),
            GalleryConfigurationItem.displacementInsetMargin(50)
        ]
    }
    
}
