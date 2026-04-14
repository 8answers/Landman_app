import '../utils/area_unit_utils.dart';

class DefaultSampleProjectService {
  static const String projectId = '46060996-8f5c-4d60-9bcd-a081a14fce2e';
  static const String ownerUserId = '3c7b5e6f-9058-4289-aee1-977ddc27a44c';
  static const String ownerEmail = 'solankiadvik@gmail.com';
  static const String projectName = 'Sample Project';
  static const String viewerRole = 'sample_viewer';
  static const String createdAt = '2026-04-12T21:14:45.152498Z';
  static const String updatedAt = '2026-04-14T13:04:07.616854Z';
  static const String projectAddress =
      'Golden Layout\nSurvey No. XXX/XX, Off Road,\nNear Plaza,\nBidara – XXXXX';
  static const String googleMapsLink =
      'https://maps.app.goo.gl/QxpZniwd1ocXJLT18';
  static const String areaUnit = 'Square Meter (sqm)';

  static bool isDefaultSampleProjectId(String? id) {
    return (id ?? '').trim() == projectId;
  }

  static bool isDefaultSampleProjectRow(Map<String, dynamic> project) {
    return isDefaultSampleProjectId((project['id'] ?? '').toString());
  }

  static Map<String, dynamic> projectListRow() {
    return <String, dynamic>{
      'id': projectId,
      'user_id': ownerUserId,
      'project_name': projectName,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'owner_email': ownerEmail,
      '_is_default_sample_project': true,
      '_read_only': true,
    };
  }

  static List<Map<String, dynamic>> ensureInProjectList(
    List<Map<String, dynamic>> projects,
  ) {
    var found = false;
    final merged = projects.map((project) {
      final copy = Map<String, dynamic>.from(project);
      if (isDefaultSampleProjectRow(copy)) {
        found = true;
        return <String, dynamic>{
          ...projectListRow(),
          ...copy,
          '_is_default_sample_project': true,
          '_read_only': true,
        };
      }
      return copy;
    }).toList(growable: true);

    if (!found) {
      merged.add(projectListRow());
    }
    return merged;
  }

  static Map<String, dynamic> projectData() {
    const totalArea = 8000.45;
    const sellingArea = 6500.36;
    const estimatedDevelopmentCost = 16000000.00;
    final canonicalAreaUnit = AreaUnitUtils.canonicalizeAreaUnit(areaUnit);

    return <String, dynamic>{
      'id': projectId,
      'projectId': projectId,
      'project_id': projectId,
      'user_id': ownerUserId,
      'owner_email': ownerEmail,
      'projectName': projectName,
      'project_name': projectName,
      'projectStatus': 'Active',
      'project_status': 'Active',
      'projectAreaUnit': canonicalAreaUnit,
      'area_unit': canonicalAreaUnit,
      'projectAddress': projectAddress,
      'project_address': projectAddress,
      'googleMapsLink': googleMapsLink,
      'google_maps_link': googleMapsLink,
      'totalArea': totalArea.toStringAsFixed(2),
      'total_area': totalArea,
      'sellingArea': sellingArea.toStringAsFixed(2),
      'selling_area': sellingArea,
      'estimatedDevelopmentCost': estimatedDevelopmentCost.toStringAsFixed(2),
      'estimated_development_cost': estimatedDevelopmentCost,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'hide_default_non_sellable_template': false,
      'hide_default_amenity_template': false,
      'nonSellableArea': '0.00',
      'allInCost': '0.00',
      'totalExpenses': '0.00',
      'totalLayouts': 0,
      'totalPlots': 0,
      'soldPlots': 0,
      'availablePlots': 0,
      'totalSalesValue': '0.00',
      'avgSalesPrice': '0.00',
      'grossProfit': '0.00',
      'netProfit': '0.00',
      'profitMargin': '0.00',
      'roi': '0.00',
      'totalPMCompensation': '0.00',
      'totalAgentCompensation': '0.00',
      'totalCompensation': '0.00',
      'amenityLayoutImageName': '',
      'amenityLayoutImagePath': '',
      'amenityLayoutImageDocId': '',
      'amenityLayoutImageExtension': '',
      'partners': <Map<String, dynamic>>[],
      'expenses': <Map<String, dynamic>>[],
      'nonSellableAreas': <Map<String, dynamic>>[],
      'amenityAreas': <Map<String, dynamic>>[],
      'plots': <Map<String, dynamic>>[],
      'layouts': <Map<String, dynamic>>[],
      'project_managers': <Map<String, dynamic>>[],
      'agents': <Map<String, dynamic>>[],
      'plot_partners': <Map<String, dynamic>>[],
      '_is_default_sample_project': true,
      '_read_only': true,
    };
  }
}
