/**
 * Google Analytics tracking utilities
 *
 * Usage:
 * import { trackEvent, trackPageView } from '@/lib/analytics'
 * trackEvent('button_click', { button_name: 'generate_route' })
 */

declare global {
  interface Window {
    gtag?: (...args: any[]) => void;
  }
}

/**
 * Track a custom event
 * @param eventName - The name of the event (e.g., 'view_overlay', 'click_button')
 * @param params - Additional parameters for the event
 */
export function trackEvent(eventName: string, params?: Record<string, any>) {
  if (typeof window === 'undefined') {
    return;
  }

  // If gtag isn't loaded yet, queue the event
  if (!window.gtag) {
    console.warn('[GA] gtag not loaded yet, skipping event:', eventName);
    return;
  }

  try {
    window.gtag('event', eventName, params);
    console.log('[GA Event]', eventName, params);
  } catch (error) {
    console.error('[GA Error] Failed to track event:', eventName, error);
  }
}

/**
 * Track a page view
 * @param path - The page path
 * @param title - Optional page title
 */
export function trackPageView(path: string, title?: string) {
  if (typeof window === 'undefined') {
    return;
  }

  if (!window.gtag) {
    console.warn('[GA] gtag not loaded yet, skipping page view:', path);
    return;
  }

  try {
    window.gtag('event', 'page_view', {
      page_path: path,
      page_title: title || document.title,
    });
    console.log('[GA PageView]', path, title);
  } catch (error) {
    console.error('[GA Error] Failed to track page view:', path, error);
  }
}

/**
 * Track overlay views
 * @param overlayName - Name of the overlay (e.g., 'activity_overlay', 'route_gen', 'admin_login')
 * @param metadata - Additional context about the overlay
 */
export function trackOverlayView(overlayName: string, metadata?: Record<string, any>) {
  trackEvent('view_overlay', {
    overlay_name: overlayName,
    ...metadata,
  });
}

/**
 * Track dashboard interactions
 * @param action - The action performed (e.g., 'delete', 'reclassify', 'overlay')
 * @param activityType - Type of activity (run, walk, cycling)
 * @param metadata - Additional context
 */
export function trackDashboardAction(action: string, activityType?: string, metadata?: Record<string, any>) {
  trackEvent('dashboard_action', {
    action,
    activity_type: activityType,
    ...metadata,
  });
}

/**
 * Track map interactions
 * @param action - The action performed (e.g., 'polygon_select', 'jump_location', 'toggle_layer')
 * @param metadata - Additional context
 */
export function trackMapAction(action: string, metadata?: Record<string, any>) {
  trackEvent('map_action', {
    action,
    ...metadata,
  });
}

/**
 * Track route generation
 * @param method - Method used (e.g., 'valhalla', 'gpx_upload')
 * @param metadata - Route details (distance, blocks, etc.)
 */
export function trackRouteGeneration(method: string, metadata?: Record<string, any>) {
  trackEvent('generate_route', {
    method,
    ...metadata,
  });
}
