"""Example Flask integration for RouteGen API.

Add these routes to your existing Flask run map application.
"""

import requests
from flask import Blueprint, send_file, jsonify, request
from pathlib import Path
import tempfile

# Create a blueprint for RouteGen integration
routegen_bp = Blueprint('routegen', __name__, url_prefix='/routegen')

# Configuration - adjust these for your setup
ROUTEGEN_API_URL = 'http://localhost:8000'  # Or https://runmap.chouinard.me/api/routegen
DEFAULT_PROFILE = 'foot'
DEFAULT_RESAMPLE_DISTANCE = 30.0


@routegen_bp.route('/convert/<int:route_id>')
def convert_route(route_id):
    """
    Convert an existing route to turn-by-turn navigation.

    This endpoint is designed to work with routes already in your database.
    Adjust the route lookup logic to match your database schema.
    """
    # TODO: Replace with your actual database query
    # route = db.session.query(Route).get(route_id)
    # if not route:
    #     return jsonify(error='Route not found'), 404
    #
    # For demo purposes, using a placeholder:
    route = {
        'id': route_id,
        'name': 'My Route',
        'gpx_path': '/path/to/route.gpx',  # Replace with actual path
    }

    try:
        # Call RouteGen API
        response = requests.post(
            f'{ROUTEGEN_API_URL}/convert-from-path',
            json={
                'file_path': route['gpx_path'],
                'profile': request.args.get('profile', DEFAULT_PROFILE),
                'resample_distance': float(
                    request.args.get('resample', DEFAULT_RESAMPLE_DISTANCE)
                ),
                'route_name': route['name'],
            },
            timeout=120  # 2 minutes for long routes
        )

        if response.status_code == 200:
            # Save to temporary file and send
            with tempfile.NamedTemporaryFile(
                delete=False,
                suffix='-turns.gpx',
                mode='wb'
            ) as f:
                f.write(response.content)
                temp_path = f.name

            return send_file(
                temp_path,
                as_attachment=True,
                download_name=f"{route['name']}-turns.gpx",
                mimetype='application/gpx+xml'
            )
        else:
            error_detail = response.json() if response.content else 'Unknown error'
            return jsonify(error=error_detail), response.status_code

    except requests.exceptions.Timeout:
        return jsonify(
            error='Conversion timed out. Try increasing resample distance.'
        ), 504
    except requests.exceptions.ConnectionError:
        return jsonify(
            error='Could not connect to RouteGen service. Please try again later.'
        ), 503
    except Exception as e:
        return jsonify(error=str(e)), 500


@routegen_bp.route('/upload-and-convert', methods=['POST'])
def upload_and_convert():
    """
    Upload a GPX/KML file and immediately convert to turn-by-turn.

    This is useful for a dedicated upload form.
    """
    if 'file' not in request.files:
        return jsonify(error='No file uploaded'), 400

    file = request.files['file']

    if not file.filename:
        return jsonify(error='No file selected'), 400

    if not file.filename.endswith(('.gpx', '.kml')):
        return jsonify(error='File must be GPX or KML format'), 400

    try:
        # Forward file to RouteGen API
        response = requests.post(
            f'{ROUTEGEN_API_URL}/convert',
            files={'file': (file.filename, file.stream, file.content_type)},
            data={
                'profile': request.form.get('profile', DEFAULT_PROFILE),
                'resample_distance': request.form.get(
                    'resample_distance',
                    DEFAULT_RESAMPLE_DISTANCE
                ),
                'route_name': request.form.get('route_name', ''),
            },
            timeout=120
        )

        if response.status_code == 200:
            # Return converted file
            with tempfile.NamedTemporaryFile(
                delete=False,
                suffix='-turns.gpx',
                mode='wb'
            ) as f:
                f.write(response.content)
                temp_path = f.name

            output_name = Path(file.filename).stem + '-turns.gpx'

            return send_file(
                temp_path,
                as_attachment=True,
                download_name=output_name,
                mimetype='application/gpx+xml'
            )
        else:
            error_detail = response.json() if response.content else 'Unknown error'
            return jsonify(error=error_detail), response.status_code

    except Exception as e:
        return jsonify(error=str(e)), 500


@routegen_bp.route('/health')
def health():
    """Check if RouteGen API is available."""
    try:
        response = requests.get(f'{ROUTEGEN_API_URL}/health', timeout=5)
        if response.status_code == 200:
            return jsonify(status='ok', routegen_api='available')
        else:
            return jsonify(
                status='degraded',
                routegen_api='unreachable'
            ), 503
    except Exception as e:
        return jsonify(
            status='error',
            routegen_api='unreachable',
            error=str(e)
        ), 503


# -------------------------------------------------------------------
# HTML Template Examples
# -------------------------------------------------------------------

# Add this button to your route detail page:
ROUTE_DETAIL_BUTTON = '''
<div class="route-actions">
    <a href="{{ url_for('routegen.convert_route', route_id=route.id) }}"
       class="btn btn-primary"
       download="{{ route.name }}-turns.gpx">
        <i class="fa fa-directions"></i>
        Add Turn-by-Turn Navigation
    </a>
</div>
'''

# Or add a dedicated upload form:
UPLOAD_FORM = '''
<form action="{{ url_for('routegen.upload_and_convert') }}"
      method="post"
      enctype="multipart/form-data">
    <div class="form-group">
        <label for="file">GPX/KML File:</label>
        <input type="file"
               name="file"
               id="file"
               accept=".gpx,.kml"
               required>
    </div>

    <div class="form-group">
        <label for="profile">Activity Type:</label>
        <select name="profile" id="profile">
            <option value="foot">Walking/Running</option>
            <option value="bike">Cycling</option>
            <option value="car">Driving</option>
        </select>
    </div>

    <div class="form-group">
        <label for="resample_distance">Waypoint Spacing (meters):</label>
        <input type="number"
               name="resample_distance"
               id="resample_distance"
               value="30"
               min="5"
               step="5">
    </div>

    <button type="submit" class="btn btn-primary">
        Convert to Turn-by-Turn
    </button>
</form>
'''

# -------------------------------------------------------------------
# Registration in your main Flask app
# -------------------------------------------------------------------

# In your main app.py, add:
REGISTRATION_CODE = '''
from flask import Flask
from flask_integration_example import routegen_bp

app = Flask(__name__)

# Register RouteGen blueprint
app.register_blueprint(routegen_bp)

# Your existing routes...
'''

# -------------------------------------------------------------------
# Usage Examples
# -------------------------------------------------------------------

# Example 1: Convert existing route
# GET /routegen/convert/123
# Downloads: route-name-turns.gpx

# Example 2: Convert with custom settings
# GET /routegen/convert/123?profile=bike&resample=50
# Downloads: route-name-turns.gpx (with bike routing and 50m spacing)

# Example 3: Upload and convert
# POST /routegen/upload-and-convert
# Form data: file, profile, resample_distance
# Downloads: filename-turns.gpx

# Example 4: Check API health
# GET /routegen/health
# Returns: {"status": "ok", "routegen_api": "available"}
