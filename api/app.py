from flask import Flask, request, jsonify, send_file, Response
from flask_cors import CORS
from werkzeug.utils import secure_filename
from functools import wraps
import os
import subprocess
import psycopg2
from psycopg2.extras import RealDictCursor
from dotenv import load_dotenv
import requests
import logging
from logging.handlers import RotatingFileHandler
import traceback
import time
import json
from valhalla_client import ValhallaClient

# Load environment variables
load_dotenv()

app = Flask(__name__)
CORS(app)

# Configure logging (always enabled, regardless of debug mode)
log_dir = os.path.join(os.path.dirname(__file__), 'logs')
os.makedirs(log_dir, exist_ok=True)
file_handler = RotatingFileHandler(
    os.path.join(log_dir, 'api.log'),
    maxBytes=10240000,  # 10MB
    backupCount=10
)
file_handler.setFormatter(logging.Formatter(
    '%(asctime)s %(levelname)s: %(message)s [in %(pathname)s:%(lineno)d]'
))
file_handler.setLevel(logging.INFO)
app.logger.addHandler(file_handler)
app.logger.setLevel(logging.INFO)
app.logger.info('RunMap API startup')

# Configuration
GPX_DIR = os.getenv('GPX_DIR', '/home/mark/runmap/gpx')
TILES_DIR = os.getenv('TILES_DIR', '/home/mark/runmap/tiles')
SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), '..', 'scripts')

# Database configuration for subprocess calls
DB_NAME = os.getenv('DB_NAME')
DB_USER = os.getenv('DB_USER')
DB_HOST = os.getenv('DB_HOST')
DB_PASSWORD = os.getenv('PGPASSWORD')

# Database connection
def get_db():
    return psycopg2.connect(
        dbname=os.getenv('DB_NAME'),
        user=os.getenv('DB_USER'),
        password=os.getenv('PGPASSWORD'),
        host=os.getenv('DB_HOST'),
        cursor_factory=RealDictCursor
    )

# Authentication decorator
def require_api_key(f):
    """Decorator to require API key authentication for admin endpoints"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        api_key = request.headers.get('X-API-Key')
        admin_key = os.getenv('ADMIN_API_KEY')

        if not admin_key:
            return jsonify({'error': 'Server authentication not configured'}), 500

        if api_key != admin_key:
            return jsonify({'error': 'Unauthorized - Invalid or missing API key'}), 401

        return f(*args, **kwargs)
    return decorated_function

@app.route('/api/health', methods=['GET'])
def health():
    """Health check endpoint"""
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        return jsonify({'status': 'healthy', 'database': 'connected'})
    except Exception as e:
        return jsonify({'status': 'unhealthy', 'error': str(e)}), 500

@app.route('/api/tiles/version', methods=['GET'])
def tiles_version():
    """Get current tiles version for cache busting"""
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute("SELECT value FROM runmap.settings WHERE key = 'tiles_version'")
        result = cur.fetchone()
        cur.close()
        conn.close()

        if result:
            return jsonify({'version': result['value']})
        else:
            return jsonify({'version': 'unknown'}), 404
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/tiles/regenerate', methods=['POST'])
@require_api_key
def regenerate_tiles():
    """Manually trigger tile regeneration (admin only)"""
    try:
        app.logger.info('Manual tile regeneration requested')

        # Update tiles version for cache busting
        # import time
        tiles_version = int(time.time())
        subprocess.run([
            'psql', '-U', os.getenv('DB_USER'), '-d', os.getenv('DB_NAME'), '-h', os.getenv('DB_HOST'), '-c',
            f"UPDATE runmap.settings SET value = '{tiles_version}'::jsonb WHERE key = 'tiles_version';"
        ], check=True, env={**os.environ, 'PGPASSWORD': os.getenv('PGPASSWORD')})

        # Trigger tile export (synchronous - wait for completion)
        export_script = os.path.join(SCRIPTS_DIR, 'export_tiles_blocks.sh')
        app.logger.info(f'Starting tile export...')

        result = subprocess.run([export_script], capture_output=True, text=True, timeout=120)

        if result.returncode == 0:
            app.logger.info(f'Tile export completed successfully')
            return jsonify({
                'status': 'success',
                'message': 'Tiles regenerated successfully',
                'tiles_version': tiles_version
            })
        else:
            app.logger.error(f'Tile export failed: {result.stderr}')
            return jsonify({
                'status': 'error',
                'message': 'Tile export failed',
                'error': result.stderr
            }), 500

    except subprocess.TimeoutExpired:
        app.logger.error(f'Tile export timed out after 120 seconds')
        return jsonify({
            'status': 'error',
            'message': 'Tile export timed out'
        }), 500
    except Exception as e:
        app.logger.error(f'Tile regeneration failed: {str(e)}')
        return jsonify({'error': str(e)}), 500

@app.route('/api/tiles/stadia/<int:z>/<int:x>/<int:y>.png', methods=['GET'])
def stadia_proxy(z, x, y):
    """Proxy Stadia Maps tiles with API key (kept secret server-side)"""
    try:
        api_key = os.getenv('STADIA_API_KEY')
        if not api_key:
            return jsonify({'error': 'Stadia API key not configured'}), 500

        # Fetch tile from Stadia Maps
        url = f'https://tiles.stadiamaps.com/tiles/stamen_toner_lite/{z}/{x}/{y}.png?api_key={api_key}'
        response = requests.get(url, timeout=5)

        # Return the tile image
        return Response(response.content, content_type='image/png')
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/locations/bounds', methods=['GET'])
def get_location_bounds():
    """Get bounding boxes for all locations with runs"""
    try:
        conn = get_db()
        cur = conn.cursor()

        # Get bounds for each location (only runs, not walks/cycling)
        cur.execute("""
            SELECT
                location,
                ST_XMin(ST_Extent(geom)) as min_lng,
                ST_YMin(ST_Extent(geom)) as min_lat,
                ST_XMax(ST_Extent(geom)) as max_lng,
                ST_YMax(ST_Extent(geom)) as max_lat
            FROM runmap.runs_raw
            WHERE location IN ('sacramento', 'portland')
            GROUP BY location
        """)

        results = cur.fetchall()
        cur.close()
        conn.close()

        bounds = {}
        for row in results:
            bounds[row['location']] = {
                'min_lng': row['min_lng'],
                'min_lat': row['min_lat'],
                'max_lng': row['max_lng'],
                'max_lat': row['max_lat']
            }

        return jsonify({'bounds': bounds})
    except Exception as e:
        app.logger.error(f'Error getting location bounds: {e}')
        return jsonify({'error': str(e)}), 500

@app.route('/api/stats', methods=['GET'])
def stats():
    """Get coverage statistics"""
    try:
        conn = get_db()
        cur = conn.cursor()

        # Overall run stats
        cur.execute("""
            SELECT
                COUNT(*) as total_runs,
                SUM(ST_Length(geom::geography))/1000 as total_km
            FROM runmap.runs_raw
        """)
        overall = cur.fetchone()

        # Block-based coverage stats
        cur.execute("SELECT * FROM runmap.coverage_stats_blocks")
        coverage = cur.fetchone()

        # Get completion threshold
        cur.execute("SELECT runmap.get_completion_threshold()")
        threshold = cur.fetchone()
        completion_threshold = float(threshold['get_completion_threshold']) if threshold else 95.0

        # Top completed blocks (replace streets_most_complete which doesn't exist)
        cur.execute("""
            SELECT
                sb.name,
                sb.highway,
                bcs.coverage_pct,
                bcs.visited_length_m,
                bcs.total_length_m
            FROM runmap.block_coverage_segments bcs
            JOIN runmap.streets_blocks_32610 sb ON bcs.block_id = sb.block_id
            WHERE bcs.coverage_pct >= 90
            ORDER BY bcs.coverage_pct DESC, bcs.total_length_m DESC
            LIMIT 10
        """)
        top_blocks = cur.fetchall()

        cur.close()
        conn.close()

        return jsonify({
            'total_runs': overall['total_runs'],
            'total_km': float(overall['total_km']) if overall['total_km'] else 0,
            'coverage': {
                'total_blocks': coverage['total_blocks'],
                'incomplete_blocks': coverage['incomplete_blocks'],
                'complete_blocks': coverage['complete_blocks'],
                'total_length_km': float(coverage['total_length_m']) / 1000 if coverage['total_length_m'] else 0,
                'covered_length_km': float(coverage['covered_length_m']) / 1000 if coverage['covered_length_m'] else 0,
                'coverage_pct': float(coverage['overall_coverage_pct']) if coverage['overall_coverage_pct'] else 0,
                'block_completion_pct': float(coverage['block_completion_pct']) if coverage['block_completion_pct'] else 0,
                'completion_threshold_pct': completion_threshold
            },
            'top_blocks': top_blocks
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/upload', methods=['POST'])
def upload_gpx():
    """Upload GPX file and trigger processing"""
    app.logger.info('=== UPLOAD REQUEST RECEIVED ===')
    app.logger.info(f'Request headers: {dict(request.headers)}')
    app.logger.info(f'Request files: {list(request.files.keys())}')

    if 'file' not in request.files:
        app.logger.warning('No file in request')
        return jsonify({
            'status': 'error',
            'error': 'No file provided',
            'code': 'NO_FILE'
        }), 400

    file = request.files['file']
    app.logger.info(f'File received: {file.filename}')

    if file.filename == '':
        app.logger.warning('Empty filename')
        return jsonify({
            'status': 'error',
            'error': 'Empty filename',
            'code': 'EMPTY_FILENAME'
        }), 400

    if not file.filename.endswith('.gpx'):
        app.logger.warning(f'Invalid file format: {file.filename}')
        return jsonify({
            'status': 'error',
            'error': 'File must be .gpx',
            'code': 'INVALID_FORMAT'
        }), 400

    try:
        # Save file with temporary name first (for parsing)
        original_filename = secure_filename(file.filename)
        app.logger.info(f'Original filename: {original_filename}')
        temp_filepath = os.path.join(GPX_DIR, f'temp_{int(time.time())}_{original_filename}')
        file.save(temp_filepath)

        # Parse GPX to calculate workout hash (just date + hour)
        import hashlib
        import gpxpy

        with open(temp_filepath, 'r') as f:
            gpx = gpxpy.parse(f)

        # Detect activity type from GPX metadata (WorkOutDoors format)
        # WorkOutDoors includes: <trk><type>running|walking|cycling</type>
        activity_type = None
        for track in gpx.tracks:
            if track.type:
                track_type = track.type.lower()
                if track_type in ['running', 'run']:
                    activity_type = 'run'
                    break
                elif track_type in ['walking', 'walk']:
                    activity_type = 'walk'
                    break
                elif track_type in ['cycling', 'cycle', 'bike', 'biking']:
                    activity_type = 'cycling'
                    break

        # Collect all points
        all_points = []
        for track in gpx.tracks:
            for segment in track.segments:
                all_points.extend(segment.points)

        if not all_points or not all_points[0].time:
            return jsonify({
                'status': 'error',
                'error': 'GPX file missing timestamps or points',
                'code': 'NO_TIMESTAMPS'
            }), 400

        # Calculate distance, duration, and moving time
        start_time = all_points[0].time
        end_time = all_points[-1].time
        duration_seconds = int((end_time - start_time).total_seconds()) if start_time and end_time else None

        # Calculate distance AND moving time (excludes stops/breaks)
        from geopy.distance import geodesic
        total_m = 0
        moving_time_seconds = 0
        STOPPED_THRESHOLD = 0.5  # m/s - consider stopped if slower than this

        for i in range(1, len(all_points)):
            p1 = all_points[i-1]
            p2 = all_points[i]

            # Distance between points
            dist = geodesic((p1.latitude, p1.longitude), (p2.latitude, p2.longitude)).meters
            total_m += dist

            # Time between points
            if p1.time and p2.time:
                time_delta = (p2.time - p1.time).total_seconds()

                # Speed for this segment
                if time_delta > 0:
                    segment_speed = dist / time_delta

                    # Only count time if moving
                    if segment_speed > STOPPED_THRESHOLD:
                        moving_time_seconds += time_delta

        distance_km = round(total_m / 1000, 2)
        moving_time_seconds = int(moving_time_seconds)

        # Fallback: Detect activity type from average MOVING speed if not specified in GPX
        # Uses moving time (excludes stops/breaks) for accurate classification
        # Average cycling speed: 5.0+ m/s (18+ km/h)
        # Average running speed: 2.2-5.0 m/s (8-18 km/h)
        # Average walking speed: 0.5-2.0 m/s (2-7 km/h)
        if not activity_type and distance_km and moving_time_seconds and moving_time_seconds > 0:
            avg_speed_ms = (distance_km * 1000) / moving_time_seconds
            if avg_speed_ms >= 5.0:
                activity_type = 'cycling'
            elif avg_speed_ms >= 2.2:
                activity_type = 'run'
            else:
                activity_type = 'walk'

        # Default to run if still unknown
        if not activity_type:
            activity_type = 'run'

        # Extract route name from GPX or auto-generate
        import sys
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts', 'common'))
        from route_naming import get_route_name

        gpx_track_name = None
        if gpx.tracks and gpx.tracks[0].name:
            gpx_track_name = gpx.tracks[0].name

        route_name = get_route_name(gpx_track_name, start_time, activity_type, gpx.creator)
        app.logger.info(f'Generated route name: {route_name} (GPX name: {gpx_track_name})')

        # Calculate workout hash: date + time rounded to 10-minute bucket
        minute_bucket = (start_time.minute // 10) * 10
        workout_datetime = start_time.strftime(f"%Y-%m-%d %H:{minute_bucket:02d}")
        workout_hash = hashlib.sha256(workout_datetime.encode()).hexdigest()

        # Generate unique, descriptive filename
        # Format: YYYY-MM-DD_HHMM_<activity_type>_<distance_km>km.gpx
        if start_time and distance_km:
            timestamp_str = start_time.strftime("%Y-%m-%d_%H%M")
            distance_str = f"{distance_km:.1f}km"
            filename = f"{timestamp_str}_{activity_type}_{distance_str}.gpx"
            app.logger.info(f'Generated filename: {filename} (original: {original_filename})')
        else:
            # Fallback to original filename if metadata is missing
            filename = original_filename
            app.logger.warning(f'Using original filename (missing metadata): {filename}')

        # Rename temp file to final filename
        final_filepath = os.path.join(GPX_DIR, filename)
        os.rename(temp_filepath, final_filepath)
        filepath = final_filepath

        # Check if this workout already exists in any activity table
        conn = get_db()
        cur = conn.cursor()

        # Check all activity tables using UNION
        cur.execute("""
            SELECT id, filename, location, uploaded_at, 'run' as activity_type
            FROM runmap.runs_raw WHERE workout_hash = %s
            UNION ALL
            SELECT id, filename, location, uploaded_at, 'walk' as activity_type
            FROM runmap.walks_raw WHERE workout_hash = %s
            UNION ALL
            SELECT id, filename, location, uploaded_at, 'cycling' as activity_type
            FROM runmap.cycling_raw WHERE workout_hash = %s
            LIMIT 1
        """, (workout_hash, workout_hash, workout_hash))
        existing_activity = cur.fetchone()

        if existing_activity:
            # Duplicate detected - clean up the file we just saved
            app.logger.info(f'Duplicate detected: {filename} matches existing {existing_activity["activity_type"]} {existing_activity["id"]}')
            cur.close()
            conn.close()

            # Delete the duplicate file
            if os.path.exists(filepath):
                os.remove(filepath)
                app.logger.info(f'Deleted duplicate file: {filepath}')

            response_data = {
                'status': 'duplicate',
                'result': 'duplicate',  # Backward compatibility
                'message': f'{existing_activity["activity_type"].title()} already exists in database',
                'filename': filename,   # Backward compatibility - the attempted upload filename
                'existing': {
                    'activity_id': str(existing_activity['id']),
                    'activity_type': existing_activity['activity_type'],
                    'filename': existing_activity['filename'],
                    'location': existing_activity['location'],
                    'uploaded_at': existing_activity['uploaded_at'].isoformat() if existing_activity['uploaded_at'] else None
                },
                'duplicate_filename': filename
            }
            app.logger.info(f'Returning duplicate response: {response_data}')
            return jsonify(response_data), 200

        # Close the connection before calling ingest script
        cur.close()
        conn.close()

        # Use existing ingest script (which handles the GPX import and routing to correct table)
        # This will insert with the workout_hash into the appropriate table
        # Pass route_name via environment variable
        ingest_script = os.path.join(SCRIPTS_DIR, 'ingest_gpx.sh')
        ingest_env = os.environ.copy()
        ingest_env['ROUTE_NAME'] = route_name
        subprocess.run([ingest_script, filepath], check=True, env=ingest_env)

        # Determine which table to query based on activity type
        table_map = {
            'run': 'runs_raw',
            'walk': 'walks_raw',
            'cycling': 'cycling_raw'
        }
        table_name = table_map.get(activity_type, 'runs_raw')

        # Get the newly inserted activity details
        conn = get_db()
        cur = conn.cursor()
        query = f"""
            SELECT id, location, start_time, total_distance_m
            FROM runmap.{table_name}
            WHERE workout_hash = %s
        """
        cur.execute(query, (workout_hash,))
        new_activity = cur.fetchone()
        cur.close()
        conn.close()

        if not new_activity:
            return jsonify({
                'status': 'error',
                'error': f'{activity_type.title()} was not inserted',
                'code': 'INSERT_FAILED'
            }), 500

        activity_id = str(new_activity['id'])
        location = new_activity['location']

        # Note: Trigger already processed buffer and coverage!
        # We just need to refresh stats and tiles

        # Refresh block coverage stats
        env = os.environ.copy()
        env['PGPASSWORD'] = DB_PASSWORD
        subprocess.run([
            'psql', '-U', DB_USER, '-d', DB_NAME, '-h', DB_HOST, '-c',
            "REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;"
        ], env=env, check=True)

        # Update tiles version for cache busting
        # import time
        tiles_version = int(time.time())
        env = os.environ.copy()
        env['PGPASSWORD'] = DB_PASSWORD
        subprocess.run([
            'psql', '-U', DB_USER, '-d', DB_NAME, '-h', DB_HOST, '-c',
            f"UPDATE runmap.settings SET value = '{tiles_version}'::jsonb WHERE key = 'tiles_version';"
        ], env=env, check=True)

        # Trigger block-based tile export (async)
        export_script = os.path.join(SCRIPTS_DIR, 'export_tiles_blocks.sh')
        subprocess.Popen([export_script])

        app.logger.info(f'Successfully processed {activity_type}: {filename} -> {activity_id}')
        response_data = {
            'status': 'success',
            'result': 'success',  # Backward compatibility for shortcuts checking 'result'
            'message': f'{route_name} uploaded and processing will complete shortly',
            'activity_type': activity_type,
            'filename': filename,  # Backward compatibility - also in 'run' object
            'run_id': activity_id,      # Backward compatibility - also in 'run' object
            'route_name': route_name,
            'run': {
                'run_id': activity_id,
                'filename': filename,
                'location': location,
                'activity_type': activity_type,
                'route_name': route_name,
                'start_time': new_activity['start_time'].isoformat() if new_activity['start_time'] else None,
                'distance_miles': round(new_activity['total_distance_m'] / 1609.34, 2) if new_activity['total_distance_m'] else None
            },
            'tiles_version': tiles_version
        }
        app.logger.info(f'Returning success response: {response_data}')
        return jsonify(response_data), 200
    except Exception as e:
        app.logger.error(f'Upload failed: {str(e)}', exc_info=True)
        return jsonify({
            'status': 'error',
            'error': str(e),
            'code': 'PROCESSING_ERROR',
            'message': f'Upload failed: {str(e)}'
        }), 500

@app.route('/api/refresh-coverage', methods=['POST'])
def refresh_coverage():
    """Manually trigger slow path (minimal - runs only)"""
    try:
        slow_path_script = os.path.join(SCRIPTS_DIR, 'slow_path_minimal.sh')
        subprocess.Popen([slow_path_script])

        return jsonify({
            'status': 'ok',
            'message': 'Runs refresh started (minimal - no coverage calc)'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/processing-queue/failed', methods=['GET'])
@require_api_key
def get_failed_runs():
    """Get list of runs that failed processing"""
    try:
        conn = get_db()
        cur = conn.cursor()

        cur.execute("""
            SELECT
                id,
                filename,
                start_time,
                total_distance_m,
                location,
                uploaded_at,
                processing_started_at,
                processing_status,
                error_message,
                error_type,
                retry_count,
                last_error_at
            FROM runmap.failed_runs
            ORDER BY uploaded_at DESC
        """)

        failed_runs = cur.fetchall()
        cur.close()
        conn.close()

        return jsonify({
            'status': 'ok',
            'count': len(failed_runs),
            'runs': failed_runs
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/processing-queue/retry/<run_id>', methods=['POST'])
@require_api_key
def retry_run(run_id):
    """Retry processing for a failed run"""
    try:
        conn = get_db()
        cur = conn.cursor()

        # Call retry function
        cur.execute("SELECT * FROM runmap.retry_run_processing(%s::uuid)", (run_id,))
        result = cur.fetchone()

        conn.commit()
        cur.close()
        conn.close()

        if result and result['success']:
            # Trigger tile export
            export_script = os.path.join(SCRIPTS_DIR, 'export_tiles_blocks.sh')
            subprocess.Popen([export_script])

            return jsonify({
                'status': 'success',
                'message': result['message'],
                'tiles_export': 'started'
            })
        else:
            return jsonify({
                'status': 'error',
                'message': result['message'] if result else 'Unknown error'
            }), 500

    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/processing-queue/stats', methods=['GET'])
@require_api_key
def get_processing_stats():
    """Get processing queue statistics"""
    try:
        conn = get_db()
        cur = conn.cursor()

        cur.execute("""
            SELECT
                COUNT(*) FILTER (WHERE processing_status = 'processed') as processed_count,
                COUNT(*) FILTER (WHERE processing_status = 'failed') as failed_count,
                COUNT(*) FILTER (WHERE processing_status = 'pending') as pending_count,
                COUNT(*) FILTER (WHERE processing_status = 'processing') as processing_count,
                COUNT(*) as total_count
            FROM runmap.runs_raw
        """)

        stats = cur.fetchone()
        cur.close()
        conn.close()

        return jsonify({
            'status': 'ok',
            'stats': stats
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/activities', methods=['GET'])
def get_all_activities():
    """Get all activities (runs + walks + cycling) from all locations"""
    try:
        conn = get_db()
        cur = conn.cursor()

        # Union query to get all activities
        cur.execute("""
            SELECT
                id,
                filename,
                start_time,
                total_distance_m,
                duration_seconds,
                location,
                'run' as activity_type,
                processing_status,
                processing_completed_at,
                uploaded_at,
                route_name
            FROM runmap.runs_raw
            UNION ALL
            SELECT
                id,
                filename,
                start_time,
                total_distance_m,
                duration_seconds,
                location,
                'walk' as activity_type,
                NULL as processing_status,
                NULL as processing_completed_at,
                uploaded_at,
                route_name
            FROM runmap.walks_raw
            UNION ALL
            SELECT
                id,
                filename,
                start_time,
                total_distance_m,
                duration_seconds,
                location,
                'cycling' as activity_type,
                NULL as processing_status,
                NULL as processing_completed_at,
                uploaded_at,
                route_name
            FROM runmap.cycling_raw
            ORDER BY start_time DESC
        """)

        activities = cur.fetchall()
        cur.close()
        conn.close()

        return jsonify({
            'status': 'ok',
            'activities': activities
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/activities/reclassify', methods=['POST'])
@require_api_key
def reclassify_activity():
    """Move an activity between tables (runs/walks/cycling)"""
    try:
        data = request.json
        activity_id = data.get('id')
        current_type = data.get('current_type')
        new_type = data.get('new_type')

        if not all([activity_id, current_type, new_type]):
            return jsonify({'error': 'Missing required fields'}), 400

        if current_type == new_type:
            return jsonify({'error': 'New type must be different from current type'}), 400

        if current_type not in ['run', 'walk', 'cycling'] or new_type not in ['run', 'walk', 'cycling']:
            return jsonify({'error': 'Invalid activity type'}), 400

        conn = get_db()
        cur = conn.cursor()

        # Map types to table names
        table_map = {'run': 'runs_raw', 'walk': 'walks_raw', 'cycling': 'cycling_raw'}
        source_table = table_map[current_type]
        dest_table = table_map[new_type]

        # Get the activity data from source table
        cur.execute(f"""
            SELECT id, filename, geom, workout_hash, location,
                   total_distance_m, duration_seconds, start_time, uploaded_at
            FROM runmap.{source_table}
            WHERE id = %s
        """, (activity_id,))

        activity = cur.fetchone()
        if not activity:
            cur.close()
            conn.close()
            return jsonify({'error': 'Activity not found'}), 404

        # Convert Row object to tuple of VALUES (not keys) for proper parameter binding
        # psycopg2 returns a dict-like object, so we need to extract values in the correct order
        activity_tuple = (
            activity['id'],
            activity['filename'],
            activity['geom'],
            activity['workout_hash'],
            activity['location'],
            activity['total_distance_m'],
            activity['duration_seconds'],
            activity['start_time'],
            activity['uploaded_at']
        )

        # If moving FROM runs, delete processing data first
        if current_type == 'run':
            # Delete buffers
            cur.execute("DELETE FROM runmap.runs_buffered_subdiv WHERE run_id = %s", (activity_id,))
            # Note: processing_status column only exists in runs_raw, so deletion will cascade

        # Insert into destination table
        cur.execute(f"""
            INSERT INTO runmap.{dest_table}
                (id, filename, geom, workout_hash, location, total_distance_m,
                 duration_seconds, start_time, uploaded_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, activity_tuple)

        # Delete from source table
        cur.execute(f"DELETE FROM runmap.{source_table} WHERE id = %s", (activity_id,))

        conn.commit()

        # Update tiles version
        tiles_version = int(time.time())
        cur.execute("UPDATE runmap.settings SET value = %s::jsonb WHERE key = 'tiles_version'",
                   (json.dumps(tiles_version),))
        conn.commit()

        cur.close()
        conn.close()

        # Export tiles synchronously (runs in foreground)
        app.logger.info(f'Starting tile export after reclassifying {activity_id}')
        export_script = os.path.join(SCRIPTS_DIR, 'export_tiles_blocks.sh')
        try:
            result = subprocess.run([export_script], check=True, capture_output=True, text=True, timeout=120)
            app.logger.info(f'Tile export completed successfully after reclassify')
            if result.stdout:
                app.logger.info(f'Tile export stdout: {result.stdout}')
        except subprocess.TimeoutExpired:
            app.logger.error(f'Tile export timed out after 120 seconds')
        except subprocess.CalledProcessError as e:
            app.logger.error(f'Tile export failed with exit code {e.returncode}')
            if e.stderr:
                app.logger.error(f'Tile export stderr: {e.stderr}')

        return jsonify({
            'status': 'success',
            'message': f'Activity reclassified from {current_type} to {new_type}',
            'tiles_version': tiles_version
        })
    except Exception as e:
        app.logger.error(f'Reclassify error: {type(e).__name__}: {str(e)}')
        app.logger.error(f'Reclassify error details: {repr(e)}')
        # Rollback on error
        try:
            conn.rollback()
            cur.close()
            conn.close()
        except:
            pass
        return jsonify({'error': f'{type(e).__name__}: {str(e)}'}), 500

@app.route('/api/activities/delete/<activity_id>', methods=['DELETE'])
@require_api_key
def delete_activity(activity_id):
    """Delete an activity from any table"""
    try:
        activity_type = request.args.get('type')  # run, walk, or cycling
        skip_tile_update = request.args.get('skip_tile_update') == 'true'

        if not activity_type or activity_type not in ['run', 'walk', 'cycling']:
            return jsonify({'error': 'Invalid or missing activity type'}), 400

        conn = get_db()
        cur = conn.cursor()

        table_map = {'run': 'runs_raw', 'walk': 'walks_raw', 'cycling': 'cycling_raw'}
        table = table_map[activity_type]

        # Get filename before deleting (need it to delete the GPX file)
        cur.execute(f"SELECT filename FROM runmap.{table} WHERE id = %s", (activity_id,))
        result = cur.fetchone()

        if not result:
            cur.close()
            conn.close()
            return jsonify({'error': 'Activity not found'}), 404

        filename = result['filename']

        # Delete from table (cascades will handle dependent data)
        cur.execute(f"DELETE FROM runmap.{table} WHERE id = %s", (activity_id,))

        conn.commit()
        cur.close()
        conn.close()

        # Delete GPX file from disk
        gpx_path = os.path.join(GPX_DIR, filename)
        if os.path.exists(gpx_path):
            try:
                os.remove(gpx_path)
                app.logger.info(f'Deleted GPX file: {gpx_path}')
            except Exception as e:
                app.logger.error(f'Failed to delete GPX file {gpx_path}: {e}')
                # Don't fail the whole operation if file deletion fails
        else:
            app.logger.warning(f'GPX file not found (already deleted?): {gpx_path}')

        tiles_version = int(time.time())

        if not skip_tile_update:
            # Update tiles version for cache busting
            env = os.environ.copy()
            env['PGPASSWORD'] = DB_PASSWORD
            subprocess.run([
                'psql', '-U', DB_USER, '-d', DB_NAME, '-h', DB_HOST, '-c',
                f"UPDATE runmap.settings SET value = '{tiles_version}'::jsonb WHERE key = 'tiles_version';"
            ], env=env, check=True)

            # Trigger tile export (synchronous - wait for completion)
            export_script = os.path.join(SCRIPTS_DIR, 'export_tiles_blocks.sh')
            app.logger.info(f'Starting tile export after deleting {activity_type} {activity_id}...')
            try:
                subprocess.run([export_script], check=True, timeout=120)
                app.logger.info(f'Tile export completed successfully')
            except subprocess.TimeoutExpired:
                app.logger.error(f'Tile export timed out after 120 seconds')
            except subprocess.CalledProcessError as e:
                app.logger.error(f'Tile export failed: {e}')
        else:
            app.logger.info(f'Skipping tile export for deletion of {activity_id} (bulk delete mode)')

        return jsonify({
            'status': 'success',
            'message': f'Activity deleted',
            'tiles_version': tiles_version
        })
    except Exception as e:
        app.logger.error(f'Delete failed: {str(e)}', exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route('/api/activities/<activity_id>/name', methods=['PUT'])
@require_api_key
def update_activity_name(activity_id):
    """Update the route name for an activity"""
    try:
        data = request.get_json()
        new_name = data.get('name')
        activity_type = data.get('type')

        if not new_name:
            return jsonify({'error': 'New name is required'}), 400
        
        if not activity_type or activity_type not in ['run', 'walk', 'cycling']:
            return jsonify({'error': 'Invalid or missing activity type'}), 400

        conn = get_db()
        cur = conn.cursor()

        table_map = {'run': 'runs_raw', 'walk': 'walks_raw', 'cycling': 'cycling_raw'}
        table = table_map[activity_type]

        # Update database
        cur.execute(f"UPDATE runmap.{table} SET route_name = %s WHERE id = %s", (new_name, activity_id))
        
        if cur.rowcount == 0:
            cur.close()
            conn.close()
            return jsonify({'error': 'Activity not found'}), 404

        conn.commit()
        cur.close()
        conn.close()

        # Update tiles version
        tiles_version = int(time.time())
        env = os.environ.copy()
        env['PGPASSWORD'] = DB_PASSWORD
        subprocess.run([
            'psql', '-U', DB_USER, '-d', DB_NAME, '-h', DB_HOST, '-c',
            f"UPDATE runmap.settings SET value = '{tiles_version}'::jsonb WHERE key = 'tiles_version';"
        ], env=env, check=True)

        # Trigger tile export (async to be snappy)
        export_script = os.path.join(SCRIPTS_DIR, 'export_tiles_blocks.sh')
        subprocess.Popen([export_script])

        return jsonify({
            'status': 'success',
            'message': f'Route name updated to "{new_name}"',
            'tiles_version': tiles_version
        })

    except Exception as e:
        app.logger.error(f'Update name failed: {str(e)}', exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route('/api/activities/<activity_id>/gpx', methods=['GET'])
def get_activity_gpx(activity_id):
    """Fetch GPX file content for an activity to overlay on map"""
    try:
        activity_type = request.args.get('type')  # run, walk, or cycling

        if not activity_type or activity_type not in ['run', 'walk', 'cycling']:
            return jsonify({'error': 'Invalid or missing activity type'}), 400

        conn = get_db()
        cur = conn.cursor()

        table_map = {'run': 'runs_raw', 'walk': 'walks_raw', 'cycling': 'cycling_raw'}
        table = table_map[activity_type]

        # Get filename and metadata
        cur.execute(f"""
            SELECT filename, start_time, total_distance_m, location, duration_seconds
            FROM runmap.{table}
            WHERE id = %s
        """, (activity_id,))
        result = cur.fetchone()

        cur.close()
        conn.close()

        if not result:
            return jsonify({'error': 'Activity not found'}), 404

        filename = result['filename']
        start_time = result['start_time']
        distance_m = result['total_distance_m']
        location = result['location']
        duration_seconds = result['duration_seconds']

        # Read GPX file content
        gpx_path = os.path.join(GPX_DIR, filename)
        if not os.path.exists(gpx_path):
            app.logger.error(f'GPX file not found: {gpx_path}')
            return jsonify({'error': 'GPX file not found on server'}), 404

        with open(gpx_path, 'r', encoding='utf-8') as f:
            gpx_content = f.read()

        return jsonify({
            'status': 'success',
            'gpx_content': gpx_content,
            'metadata': {
                'id': activity_id,
                'type': activity_type,
                'filename': filename,
                'start_time': start_time.isoformat() if start_time else None,
                'distance_m': distance_m,
                'location': location,
                'duration_seconds': duration_seconds
            }
        })
    except Exception as e:
        app.logger.error(f'Failed to fetch GPX for activity {activity_id}: {str(e)}', exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route('/api/centroids/extract', methods=['POST'])
@require_api_key
def extract_unrun_centroids():
    """
    Extract centroids of unrun segments within a user-drawn polygon.

    Request Body:
    {
      "polygon": {
        "type": "Polygon",
        "coordinates": [[[lon, lat], [lon, lat], ...]]
      }
    }

    Response:
    {
      "status": "success",
      "count": 42,
      "centroids": [
        {
          "segment_id": 12345,
          "block_id": 789,
          "street_name": "J Street",
          "lon": -121.4944,
          "lat": 38.5816,
          "segment_length_m": 5.0
        }
      ]
    }
    """
    try:
        data = request.json

        if not data or 'polygon' not in data:
            return jsonify({
                'status': 'error',
                'message': 'Missing polygon in request body'
            }), 400

        polygon = data['polygon']

        # Validate polygon structure
        if not isinstance(polygon, dict) or polygon.get('type') != 'Polygon':
            return jsonify({
                'status': 'error',
                'message': 'Invalid polygon format - must be GeoJSON Polygon'
            }), 400

        if 'coordinates' not in polygon or not polygon['coordinates']:
            return jsonify({
                'status': 'error',
                'message': 'Polygon missing coordinates'
            }), 400

        # Check for minimum vertices (at least 3 points + closing point = 4 total)
        if len(polygon['coordinates'][0]) < 4:
            return jsonify({
                'status': 'error',
                'message': 'Polygon must have at least 3 vertices'
            }), 400

        # Convert polygon to GeoJSON string for PostGIS
        polygon_geojson = json.dumps(polygon)

        app.logger.info(f'Extracting unrun centroids for polygon: {polygon_geojson[:100]}...')

        conn = get_db()
        cur = conn.cursor()

        # Calculate polygon area to prevent abuse (using ST_Area in UTM for accurate km²)
        cur.execute("""
            SELECT ST_Area(ST_Transform(ST_GeomFromGeoJSON(%s), 32610)) / 1000000.0 as area_km2
        """, (polygon_geojson,))
        area_result = cur.fetchone()
        area_km2 = area_result['area_km2'] if area_result else 0

        MAX_AREA_KM2 = 25.0  # Prevent city-wide selections
        if area_km2 > MAX_AREA_KM2:
            cur.close()
            conn.close()
            return jsonify({
                'status': 'error',
                'message': f'Selection area too large ({area_km2:.1f} km²). Maximum allowed: {MAX_AREA_KM2} km²'
            }), 400

        # Extract unrun block centroids within polygon (aggregated to block level)
        # For each block, only count unvisited segments that are actually inside the polygon
        # This handles cases where a long block (like 30th St) has unvisited segments
        # both inside and outside the polygon

        # First, transform the polygon to UTM once
        polygon_utm = f"ST_Transform(ST_GeomFromGeoJSON('{polygon_geojson}'), 32610)"

        cur.execute(f"""
            WITH unvisited_segments_in_polygon AS (
                -- Find segments that are NOT visited AND within the polygon
                SELECT
                    bs.block_id,
                    b.name AS street_name,
                    bs.segment_geom,
                    bs.segment_length_m,
                    bs.segment_id
                FROM runmap.block_segments bs
                JOIN runmap.block_segment_visited bsv ON bs.segment_id = bsv.segment_id
                JOIN runmap.streets_blocks_32610 b ON bs.block_id = b.block_id
                WHERE bsv.visited = FALSE
                    -- Use ST_Within instead of ST_Intersects to avoid edge-touching matches
                    AND ST_Within(bs.segment_geom, {polygon_utm})
            ),
            block_aggregates AS (
                -- Aggregate segments per block (per portion of block in polygon)
                SELECT
                    us.block_id,
                    us.street_name,
                    ST_Collect(us.segment_geom) as collected_geom,
                    SUM(us.segment_length_m) as total_unvisited_length_m,
                    COUNT(*) as unvisited_segment_count,
                    b.block_length_m,
                    bcs.coverage_pct as overall_coverage_pct
                FROM unvisited_segments_in_polygon us
                JOIN runmap.streets_blocks_32610 b ON us.block_id = b.block_id
                LEFT JOIN runmap.block_coverage_segments bcs ON us.block_id = bcs.block_id
                GROUP BY us.block_id, us.street_name, b.block_length_m, bcs.coverage_pct
            ),
            filtered_blocks AS (
                -- Only return blocks that are actually incomplete (<75% coverage overall)
                -- This filters out "green" blocks that just have 1-2 unvisited edge segments
                -- Matches the map threshold: >=75% = green (complete), <75% = purple/grey (incomplete)
                SELECT
                    block_id,
                    street_name,
                    collected_geom,
                    total_unvisited_length_m,
                    unvisited_segment_count,
                    block_length_m,
                    overall_coverage_pct as coverage_pct
                FROM block_aggregates
                WHERE COALESCE(overall_coverage_pct, 0) < 75
                    -- Only include blocks with <75% overall coverage (matches map "green" threshold)
            )
            SELECT
                fb.block_id,
                COALESCE(fb.street_name, 'Unnamed') as street_name,
                -- Extract ALL vertices from the BLOCK'S original geometry (not the collected segments!)
                -- This captures the natural shape with ~2-5 vertices per block instead of 20+ from 5m segments
                ST_AsGeoJSON(ST_Transform(b.geom_32610, 4326))::json AS full_geometry,
                -- Also keep individual start/end/centroid for backwards compatibility
                ST_Y(ST_Transform(ST_StartPoint(ST_LineMerge(fb.collected_geom)), 4326)) AS start_lat,
                ST_X(ST_Transform(ST_StartPoint(ST_LineMerge(fb.collected_geom)), 4326)) AS start_lon,
                ST_Y(ST_Transform(ST_EndPoint(ST_LineMerge(fb.collected_geom)), 4326)) AS end_lat,
                ST_X(ST_Transform(ST_EndPoint(ST_LineMerge(fb.collected_geom)), 4326)) AS end_lon,
                ST_Y(ST_Transform(ST_Centroid(fb.collected_geom), 4326)) AS centroid_lat,
                ST_X(ST_Transform(ST_Centroid(fb.collected_geom), 4326)) AS centroid_lon,
                fb.total_unvisited_length_m,
                fb.unvisited_segment_count,
                ROUND(COALESCE(fb.coverage_pct, 0)::numeric, 1) as coverage_pct,
                -- Get segment IDs for debugging
                ARRAY_AGG(us.segment_id ORDER BY us.segment_id) as segment_ids
            FROM filtered_blocks fb
            JOIN unvisited_segments_in_polygon us ON fb.block_id = us.block_id AND fb.street_name = us.street_name
            JOIN runmap.streets_blocks_32610 b ON fb.block_id = b.block_id
            GROUP BY fb.block_id, fb.street_name, fb.collected_geom,
                     fb.total_unvisited_length_m, fb.unvisited_segment_count, fb.coverage_pct, b.geom_32610
            ORDER BY street_name, block_id
            LIMIT 5000;  -- Safety limit
        """)

        centroids = cur.fetchall()

        # Debug logging - show what blocks were returned with segment IDs
        for row in centroids:
            app.logger.info(f"Block {row['block_id']}: {row['street_name']} - start ({row['start_lat']:.6f}, {row['start_lon']:.6f}) end ({row['end_lat']:.6f}, {row['end_lon']:.6f}) - {row['coverage_pct']}% coverage, {row['unvisited_segment_count']} segments ({row['total_unvisited_length_m']:.1f}m), segment_ids: {row['segment_ids']}")

        cur.close()
        conn.close()

        app.logger.info(f'Found {len(centroids)} unrun blocks in polygon (area: {area_km2:.2f} km²)')

        # Convert to list of dicts with endpoints AND full geometry
        blocks_list = []
        for row in centroids:
            # Extract all coordinates from the full geometry
            geom_coords = row['full_geometry']['coordinates']

            blocks_list.append({
                'block_id': row['block_id'],
                'street_name': row['street_name'],
                'start_lat': float(row['start_lat']),
                'start_lon': float(row['start_lon']),
                'end_lat': float(row['end_lat']),
                'end_lon': float(row['end_lon']),
                'centroid_lat': float(row['centroid_lat']),
                'centroid_lon': float(row['centroid_lon']),
                'total_unvisited_length_m': float(row['total_unvisited_length_m']),
                'unvisited_segment_count': row['unvisited_segment_count'],
                'coverage_pct': float(row['coverage_pct']),
                'segment_ids': row['segment_ids'],  # For debugging
                'geometry_coordinates': geom_coords  # Full list of [lon, lat] points
            })

        if len(blocks_list) == 0:
            return jsonify({
                'status': 'success',
                'count': 0,
                'message': 'No unrun segments found in selected area - this area is fully covered!',
                'blocks': [],
                'waypoints': [],
                'coordinates_string': '',
                'graphhopper_url': ''
            })

        # Create waypoints list: for each block, add start point then end point
        # This ensures GraphHopper routes the full length of each block
        waypoints = []
        for block in blocks_list:
            # Add start point
            waypoints.append({
                'lat': block['start_lat'],
                'lon': block['start_lon'],
                'block_id': block['block_id'],
                'street_name': block['street_name'],
                'type': 'start'
            })
            # Add end point
            waypoints.append({
                'lat': block['end_lat'],
                'lon': block['end_lon'],
                'block_id': block['block_id'],
                'street_name': block['street_name'],
                'type': 'end'
            })

        # Create a formatted coordinate string (start, end for each block)
        coordinates_string = ' '.join([f"{w['lat']},{w['lon']}" for w in waypoints])

        return jsonify({
            'status': 'success',
            'count': len(blocks_list),
            'waypoint_count': len(waypoints),
            'area_km2': round(area_km2, 2),
            'blocks': blocks_list,
            'waypoints': waypoints,
            'coordinates_string': coordinates_string
        })

    except psycopg2.Error as e:
        app.logger.error(f'Database error extracting centroids: {str(e)}')
        return jsonify({
            'status': 'error',
            'message': f'Database error: {str(e)}'
        }), 500
    except Exception as e:
        app.logger.error(f'Error extracting centroids: {str(e)}', exc_info=True)
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500

@app.route('/api/route/pgrouting', methods=['POST'])
@require_api_key
def route_with_pgrouting():
    """
    Route between waypoints using pgRouting on actual street network.
    Returns complete street geometry to avoid parallel street duplication.

    Request Body:
    {
      "waypoints": [
        {"lat": 38.57, "lon": -121.47},
        {"lat": 38.56, "lon": -121.46}
      ]
    }
    """
    try:
        data = request.get_json()
        waypoints = data.get('waypoints', [])

        if len(waypoints) < 2:
            return jsonify({
                'status': 'error',
                'message': 'At least 2 waypoints required'
            }), 400

        conn = get_db()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        # Step 1: Find nearest vertex for each waypoint
        vertex_mapping = []
        for idx, wp in enumerate(waypoints):
            cur.execute("""
                SELECT id,
                       ST_Distance(
                           the_geom::geography,
                           ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography
                       ) as dist
                FROM runmap.streets_reference_vertices_pgr
                ORDER BY dist
                LIMIT 1
            """, (wp['lon'], wp['lat']))
            vertex = cur.fetchone()
            if vertex:
                vertex_mapping.append({'idx': idx, 'vertex_id': vertex['id'], 'wp': wp})

        if len(vertex_mapping) < 2:
            return jsonify({
                'status': 'error',
                'message': 'Could not find vertices near waypoints'
            }), 404

        # Step 2: Build distance matrix between all vertices
        vertex_ids = [v['vertex_id'] for v in vertex_mapping]

        # Create temp table with vertex IDs for TSP
        cur.execute("DROP TABLE IF EXISTS temp_tsp_vertices")
        cur.execute("""
            CREATE TEMP TABLE temp_tsp_vertices (
                id SERIAL PRIMARY KEY,
                vertex_id BIGINT
            )
        """)

        for vid in vertex_ids:
            cur.execute("INSERT INTO temp_tsp_vertices (vertex_id) VALUES (%s)", (vid,))

        # Calculate pairwise distances using pgr_dijkstraCost
        # This creates a complete distance matrix
        # Format vertex_ids as PostgreSQL array literal
        vertex_array_str = '{' + ','.join(str(vid) for vid in vertex_ids) + '}'

        cur.execute(f"""
            SELECT *
            FROM pgr_dijkstraCost(
                'SELECT ogc_fid as id, source, target, length_m as cost, length_m as reverse_cost
                 FROM runmap.streets_reference WHERE runnable = true',
                '{vertex_array_str}'::BIGINT[],
                '{vertex_array_str}'::BIGINT[],
                directed := false
            )
        """)

        cost_matrix = cur.fetchall()

        # Step 3: Build distance lookup dictionary
        distances = {}
        for row in cost_matrix:
            key = (row['start_vid'], row['end_vid'])
            distances[key] = row['agg_cost']

        # Step 4: Greedy nearest-neighbor TSP in Python (more robust than pgr_TSP)
        # Start from first waypoint
        current_vid = vertex_ids[0]
        unvisited = set(vertex_ids[1:])  # All except start
        tsp_order = [current_vid]

        while unvisited:
            nearest_vid = None
            nearest_dist = float('inf')

            for vid in unvisited:
                dist = distances.get((current_vid, vid), float('inf'))
                if dist < nearest_dist:
                    nearest_dist = dist
                    nearest_vid = vid

            if nearest_vid is None:
                # No path found, just pick any remaining vertex
                nearest_vid = next(iter(unvisited))

            tsp_order.append(nearest_vid)
            unvisited.remove(nearest_vid)
            current_vid = nearest_vid

        # Add return to start for round trip
        tsp_order.append(vertex_ids[0])

        # Step 5: Route between consecutive vertices in TSP order
        all_route_coords = []
        total_distance = 0

        for i in range(len(tsp_order) - 1):
            from_vid = tsp_order[i]
            to_vid = tsp_order[i + 1]

            # Route using pgr_dijkstra between these vertices
            cur.execute("""
                SELECT
                    r.seq,
                    r.node,
                    r.edge,
                    r.cost,
                    ST_AsGeoJSON(s.geom)::json as geom_json,
                    s.length_m
                FROM pgr_dijkstra(
                    'SELECT ogc_fid as id, source, target, length_m as cost, length_m as reverse_cost
                     FROM runmap.streets_reference WHERE runnable = true',
                    %s, %s, directed := false
                ) r
                LEFT JOIN runmap.streets_reference s ON r.edge = s.ogc_fid
                WHERE r.edge IS NOT NULL
                ORDER BY r.seq
            """, (from_vid, to_vid))

            route_segments = cur.fetchall()

            # Extract coordinates from each segment
            for segment in route_segments:
                if segment['geom_json']:
                    geom = segment['geom_json']
                    if geom['type'] == 'LineString':
                        coords = geom['coordinates']
                        all_route_coords.extend(coords)
                    total_distance += segment['length_m'] or 0

        cur.close()
        conn.close()

        if not all_route_coords:
            return jsonify({
                'status': 'error',
                'message': 'No route found'
            }), 404

        return jsonify({
            'status': 'success',
            'route': {
                'type': 'LineString',
                'coordinates': all_route_coords
            },
            'distance_meters': total_distance,
            'distance_miles': total_distance / 1609.34,
            'waypoint_count': len(waypoints),
            'optimized': True
        })

    except Exception as e:
        app.logger.error(f'Routing error: {str(e)}', exc_info=True)
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500

@app.route('/api/route/valhalla', methods=['POST'])
@require_api_key
def route_with_valhalla():
    """
    Route through unrun blocks using Valhalla with guaranteed block coverage.

    This endpoint uses the Valhalla routing engine to create a route that
    visits all specified unrun blocks. Unlike simple waypoint routing, this
    ensures that the route actually traverses the full length of each block,
    not just passes near it.

    Key features:
    - Uses Valhalla's optimized_route endpoint for TSP optimization
    - Validates route coverage using PostGIS intersection tests
    - Automatically adds intermediate waypoints if blocks are missed
    - Returns GeoJSON LineString suitable for MapLibre display

    Request Body:
    {
      "blocks": [
        {
          "block_id": 789,
          "start_lat": 38.5816,
          "start_lon": -121.4944,
          "end_lat": 38.5820,
          "end_lon": -121.4950,
          "centroid_lat": 38.5818,
          "centroid_lon": -121.4947,
          "street_name": "J Street"
        },
        ...
      ],
      "use_optimized": true,  // Optional: use TSP optimization (default: true)
      "max_retries": 2  // Optional: max retry attempts (default: 2)
    }

    Response:
    {
      "status": "success",
      "route": {
        "type": "Feature",
        "geometry": {
          "type": "LineString",
          "coordinates": [[lon, lat], ...]
        },
        "properties": {
          "distance_km": 5.2,
          "time_seconds": 1872,
          "blocks_total": 42,
          "blocks_covered": 42
        }
      },
      "coverage_validation": {
        "blocks_covered": 42,
        "blocks_total": 42,
        "missing_blocks": [],
        "coverage_pct": 100.0
      },
      "valhalla_response": {...}  // Full Valhalla API response
    }
    """
    try:
        data = request.get_json()
        blocks = data.get('blocks', [])
        start_point = data.get('start_point')  # {lat, lon} for circular route start/end
        use_optimized = data.get('use_optimized', True)
        max_retries = data.get('max_retries', 2)

        if not blocks:
            return jsonify({
                'status': 'error',
                'message': 'No blocks provided'
            }), 400

        if not start_point or 'lat' not in start_point or 'lon' not in start_point:
            return jsonify({
                'status': 'error',
                'message': 'start_point is required with lat and lon fields'
            }), 400

        # Validate block format
        required_fields = ['block_id', 'start_lat', 'start_lon', 'end_lat', 'end_lon']
        for block in blocks:
            missing = [f for f in required_fields if f not in block]
            if missing:
                return jsonify({
                    'status': 'error',
                    'message': f'Block missing required fields: {missing}'
                }), 400

        app.logger.info(f'Routing through {len(blocks)} blocks using Valhalla')

        # Initialize Valhalla client
        valhalla_url = os.getenv('VALHALLA_URL', 'https://valhalla.chouinard.me')
        client = ValhallaClient(base_url=valhalla_url)

        # Get database connection for coverage validation
        conn = get_db()

        # Route with block coverage guarantee
        result = client.ensure_block_coverage(
            blocks=blocks,
            conn=conn,
            start_point=start_point,
            use_optimized=use_optimized,
            max_retries=max_retries
        )

        app.logger.info(
            f'Valhalla routing complete: {result["coverage_validation"]["blocks_covered"]}'
            f'/{result["coverage_validation"]["blocks_total"]} blocks covered '
            f'({result["coverage_validation"]["coverage_pct"]:.1f}%)'
        )

        return jsonify({
            'status': 'success',
            'route': result['geojson'],
            'coverage_validation': result['coverage_validation'],
            'valhalla_response': {
                'distance_km': result['route']['distance_km'],
                'time_seconds': result['route']['time_seconds'],
                'waypoint_count': len(result['route']['decoded_polyline'])
            }
        })

    except Exception as e:
        app.logger.error(f'Valhalla routing error: {str(e)}', exc_info=True)
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500

@app.route('/api/route/valhalla/gpx', methods=['POST'])
@require_api_key
def export_valhalla_route_gpx():
    """
    Convert a Valhalla route GeoJSON to GPX format for Garmin/watch upload.

    Request Body:
    {
      "route": {
        "type": "Feature",
        "geometry": {
          "type": "LineString",
          "coordinates": [[lon, lat], ...]
        },
        "properties": {...}
      }
    }

    Returns:
        GPX file download (application/gpx+xml)
    """
    try:
        from valhalla_client import convert_route_to_gpx

        data = request.get_json()
        route = data.get('route')

        if not route or 'geometry' not in route:
            return jsonify({
                'status': 'error',
                'message': 'Invalid route data'
            }), 400

        # Extract coordinates from GeoJSON
        coordinates = route['geometry']['coordinates']

        # Convert to the format expected by convert_route_to_gpx
        # GeoJSON: [lon, lat] -> GPX needs: [lat, lon]
        decoded_polyline = [(lat, lon) for lon, lat in coordinates]

        # Create a route_result dict in the format expected by convert_route_to_gpx
        route_result = {
            'decoded_polyline': decoded_polyline
        }

        # Generate GPX
        gpx_string = convert_route_to_gpx(route_result, 'valhalla-route.gpx')

        # Return as downloadable file
        from flask import make_response
        response = make_response(gpx_string)
        response.headers['Content-Type'] = 'application/gpx+xml'
        response.headers['Content-Disposition'] = 'attachment; filename=valhalla-route.gpx'

        return response

    except Exception as e:
        app.logger.error(f'GPX export error: {str(e)}', exc_info=True)
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500

# RouteGen API Integration
@app.route('/api/routegen/preview', methods=['POST'])
def routegen_preview():
    """
    Upload a GPX file temporarily and return GeoJSON for map preview.
    File is stored temporarily and automatically cleaned up.
    """
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400

    file = request.files['file']

    if not file.filename or not file.filename.endswith('.gpx'):
        return jsonify({'error': 'File must be GPX format'}), 400

    try:
        import tempfile
        import gpxpy

        # Save to temporary file
        filename = secure_filename(file.filename)
        with tempfile.NamedTemporaryFile(mode='w+b', suffix='.gpx', delete=False) as temp_file:
            file.save(temp_file.name)
            temp_path = temp_file.name

        # Parse GPX to get coordinates for preview
        with open(temp_path, 'r') as f:
            gpx = gpxpy.parse(f)

        # Extract all track points as GeoJSON
        coordinates = []
        for track in gpx.tracks:
            for segment in track.segments:
                for point in segment.points:
                    coordinates.append([point.longitude, point.latitude])

        if not coordinates:
            os.remove(temp_path)
            return jsonify({'error': 'No track points found in GPX'}), 400

        # Calculate bounds for map centering
        lngs = [c[0] for c in coordinates]
        lats = [c[1] for c in coordinates]
        bounds = {
            'min_lng': min(lngs),
            'min_lat': min(lats),
            'max_lng': max(lngs),
            'max_lat': max(lats)
        }

        return jsonify({
            'status': 'success',
            'temp_path': temp_path,  # Client will send this back for conversion
            'filename': filename,
            'geojson': {
                'type': 'Feature',
                'geometry': {
                    'type': 'LineString',
                    'coordinates': coordinates
                },
                'properties': {
                    'filename': filename,
                    'point_count': len(coordinates)
                }
            },
            'bounds': bounds
        })

    except Exception as e:
        app.logger.error(f'Preview failed: {str(e)}', exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route('/api/routegen/convert', methods=['POST'])
def routegen_convert():
    """
    Convert a GPX file to turn-by-turn navigation using RouteGen API.

    Request body (JSON):
    {
      "temp_path": "/tmp/xyz.gpx",  # From preview endpoint
      "format": "gpx" or "tcx",
      "resample_distance": 30  # Optional, meters between waypoints
    }

    Returns: GPX or TCX file for download
    """
    try:
        data = request.json
        temp_path = data.get('temp_path')
        output_format = data.get('format', 'gpx').lower()
        resample_distance = data.get('resample_distance', 30)

        if not temp_path or not os.path.exists(temp_path):
            return jsonify({'error': 'Invalid or missing temp file'}), 400

        if output_format not in ['gpx', 'tcx']:
            return jsonify({'error': 'Format must be gpx or tcx'}), 400

        # Call RouteGen API
        routegen_api_url = 'http://localhost:8000/convert'

        with open(temp_path, 'rb') as f:
            files = {'file': (os.path.basename(temp_path), f, 'application/gpx+xml')}
            form_data = {
                'profile': 'foot',  # Running profile
                'resample_distance': str(resample_distance),
            }

            app.logger.info(f'Calling RouteGen API at {routegen_api_url}')
            response = requests.post(
                routegen_api_url,
                files=files,
                data=form_data,
                timeout=120  # 2 minutes for long routes
            )

        # Clean up temp file
        try:
            os.remove(temp_path)
        except:
            pass

        if response.status_code != 200:
            error_msg = response.text if response.text else 'RouteGen conversion failed'
            app.logger.error(f'RouteGen API error: {error_msg}')
            return jsonify({'error': error_msg}), response.status_code

        # RouteGen returns GPX by default
        # If TCX requested, we need to convert (for now, just return GPX)
        if output_format == 'tcx':
            # TODO: Convert GPX to TCX format
            # For now, return error
            return jsonify({'error': 'TCX format not yet supported'}), 501

        # Return the GPX file
        output_filename = f"route-turns.gpx"

        return Response(
            response.content,
            mimetype='application/gpx+xml',
            headers={
                'Content-Disposition': f'attachment; filename="{output_filename}"'
            }
        )

    except requests.exceptions.Timeout:
        return jsonify({'error': 'RouteGen API timeout. Try increasing resample distance.'}), 504
    except requests.exceptions.ConnectionError:
        return jsonify({'error': 'Cannot connect to RouteGen service'}), 503
    except Exception as e:
        app.logger.error(f'Conversion failed: {str(e)}', exc_info=True)
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    port = int(os.getenv('FLASK_RUN_PORT', 5001))
    app.run(host='0.0.0.0', port=port, debug=True)
