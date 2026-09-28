# Sponsored-feed integration notes

These observations apply to Threads 448.0.0 only. Runtime captures identified the sponsored-item preparation hook on `BCNMainFeedAdsInsertionSurfaceHandler` as the useful filtering seam. The nearby insertion pipeline also includes `BCNMainFeedAdsAwareDataSource` and `BCNMainFeedAdsInsertionDataSource`, but generic insertion callbacks were not treated as ad-only because they can handle ordinary feed content.

Matter calls the original prepare method first. Its optional filter runs only when compiled in and the Block Sponsored Posts preference is on. It requires the strict sponsored-item checks already implemented in `Tweak.xm`; uncertain or unsupported values pass through unchanged. Other Threads versions may use different classes, selectors, or data flow.

Static names and selector metadata informed the investigation but are not a general description of Meta's ad-delivery system. The repository intentionally stores no Threads binary, app resources, or disassembly dump.
