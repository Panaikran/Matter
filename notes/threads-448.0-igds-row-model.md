# Threads Settings row integration decision

Runtime observation on Threads 448.0.0 found the Settings controller `BCNSettings.BCNSettingsViewController` using an `IGListAdapter`. Its normal list includes an `IGDSListSectionController` with 14 `IGDSListCellViewModel` items rendered as `IGDSListCellCollectionViewCell` cells.

Static metadata identified `IGDSListCellTextViewModel` as the `textViewModel:` type at an analyzed construction site. Threads creates this model through generated private code; no safe external initializer or factory was established. The associated icon/add-on and full initializer contract were not sufficiently established for Matter to construct these private models.

Matter therefore does not instantiate `IGDSListCellTextViewModel`, `IGDSListCellViewModel`, `IGDSListCellAddOnViewModel`, or `IGDSIconAsset`. It adds its own diffable marker to the validated top-level Settings objects, returns a Matter-owned `IGListSectionController` subclass, renders one Matter-owned UIKit cell, and routes selection to `MatterSettingsViewController`. The original 14 Threads rows and their section are left unchanged.

The injection is scoped to the exact Settings controller and adapter. It snapshots the original Swift-backed collection through bounded Objective-C fast enumeration, validates the six known runtime classes, and fails open if the layout or runtime contract differs. `MATTER_SETTINGS_INJECTION` controls whether the feature is compiled in.
