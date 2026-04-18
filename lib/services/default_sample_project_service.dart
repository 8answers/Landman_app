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
    const nonSellableArea = 900.09;
    const amenityArea = 600.00;
    const allInCost = 2550.20;
    const estimatedDevelopmentCost = 16000000.00;
    const totalExpenses = 1450000.00;
    const totalSalesValue = 21950000.00;
    const grossProfit = 5950000.00;
    const netProfit = 4500000.00;
    const profitMargin = 20.50;
    const roi = 28.12;
    const totalPMCompensation = 450000.00;
    const totalAgentCompensation = 225000.00;
    const totalCompensation = totalPMCompensation + totalAgentCompensation;
    const avgSalesPrice = 3250.00;
    final canonicalAreaUnit = AreaUnitUtils.canonicalizeAreaUnit(areaUnit);
    const partners = <Map<String, dynamic>>[
      {
        'id': 'sample_partner_1',
        'name': 'Apex Holdings',
        'share_percentage': 55,
      },
      {
        'id': 'sample_partner_2',
        'name': 'Bluefield Ventures',
        'share_percentage': 45,
      },
    ];
    const projectManagers = <Map<String, dynamic>>[
      {
        'id': 'sample_pm_1',
        'name': 'Ritika Sharma',
        'compensation_type': 'percentage',
        'earning_type': 'project',
        'percentage': 1.25,
      },
    ];
    const agents = <Map<String, dynamic>>[
      {
        'id': 'sample_agent_1',
        'name': 'Karan Mehta',
        'compensation_type': 'percentage',
        'earning_type': 'sale',
        'percentage': 0.75,
      },
      {
        'id': 'sample_agent_2',
        'name': 'Direct Sale',
        'compensation_type': 'fixed',
        'earning_type': 'sale',
        'fixed_fee': 0.0,
      },
    ];
    const expenses = <Map<String, dynamic>>[
      {
        'id': 'sample_exp_1',
        'category': 'Land Development',
        'amount': 650000.00,
      },
      {
        'id': 'sample_exp_2',
        'category': 'Approvals & Legal',
        'amount': 300000.00,
      },
      {
        'id': 'sample_exp_3',
        'category': 'Marketing',
        'amount': 500000.00,
      },
    ];
    const nonSellableAreas = <Map<String, dynamic>>[
      {
        'id': 'sample_nsa_1',
        'name': 'Internal Roads',
        'area': nonSellableArea,
      },
    ];
    const amenityAreas = <Map<String, dynamic>>[
      {
        'id': 'sample_amenity_1',
        'name': 'Clubhouse',
        'area': 350.00,
        'all_in_cost': 1800.00,
        'status': 'sold',
        'sale_price': 2200.00,
        'sale_value': 770000.00,
        'buyer_name': 'Community Association',
      },
      {
        'id': 'sample_amenity_2',
        'name': 'Park & Open Gym',
        'area': 250.00,
        'all_in_cost': 1700.00,
        'status': 'available',
      },
    ];
    const layouts = <Map<String, dynamic>>[
      {
        'id': 'sample_layout_a',
        'name': 'Layout A',
        'plots': [
          {
            'id': 'sample_plot_a1',
            'plot_number': 'A-101',
            'area': 111.48,
            'area_sqft': 1200.00,
            'status': 'sold',
            'purchase_rate': 2450.00,
            'sale_price': 3200.00,
            'buyer_name': 'Rahul Verma',
            'agent_name': 'Karan Mehta',
            'partners': ['Apex Holdings'],
          },
          {
            'id': 'sample_plot_a2',
            'plot_number': 'A-102',
            'area': 120.77,
            'area_sqft': 1300.00,
            'status': 'sold',
            'purchase_rate': 2450.00,
            'sale_price': 3300.00,
            'buyer_name': 'Nisha Reddy',
            'agent_name': 'Karan Mehta',
            'partners': ['Bluefield Ventures'],
          },
          {
            'id': 'sample_plot_a3',
            'plot_number': 'A-103',
            'area': 97.55,
            'area_sqft': 1050.00,
            'status': 'available',
            'purchase_rate': 2500.00,
            'sale_price': 0.00,
            'partners': ['Apex Holdings'],
          },
        ],
      },
      {
        'id': 'sample_layout_b',
        'name': 'Layout B',
        'plots': [
          {
            'id': 'sample_plot_b1',
            'plot_number': 'B-201',
            'area': 102.19,
            'area_sqft': 1100.00,
            'status': 'pending',
            'purchase_rate': 2550.00,
            'sale_price': 3100.00,
            'agent_name': 'Karan Mehta',
            'partners': ['Bluefield Ventures'],
          },
          {
            'id': 'sample_plot_b2',
            'plot_number': 'B-202',
            'area': 106.84,
            'area_sqft': 1150.00,
            'status': 'available',
            'purchase_rate': 2550.00,
            'sale_price': 0.00,
            'partners': ['Apex Holdings', 'Bluefield Ventures'],
          },
        ],
      },
    ];
    const plots = <Map<String, dynamic>>[
      {
        'id': 'sample_plot_a1',
        'layout_id': 'sample_layout_a',
        'layout_name': 'Layout A',
        'plot_number': 'A-101',
        'area': 1200.00,
        'all_in_cost_per_sqft': 2450.00,
        'status': 'sold',
        'sale_price': 3200.00,
        'buyer_name': 'Rahul Verma',
        'agent_name': 'Karan Mehta',
        'partners': ['Apex Holdings'],
      },
      {
        'id': 'sample_plot_a2',
        'layout_id': 'sample_layout_a',
        'layout_name': 'Layout A',
        'plot_number': 'A-102',
        'area': 1300.00,
        'all_in_cost_per_sqft': 2450.00,
        'status': 'sold',
        'sale_price': 3300.00,
        'buyer_name': 'Nisha Reddy',
        'agent_name': 'Karan Mehta',
        'partners': ['Bluefield Ventures'],
      },
      {
        'id': 'sample_plot_a3',
        'layout_id': 'sample_layout_a',
        'layout_name': 'Layout A',
        'plot_number': 'A-103',
        'area': 1050.00,
        'all_in_cost_per_sqft': 2500.00,
        'status': 'available',
        'sale_price': 0.00,
        'partners': ['Apex Holdings'],
      },
      {
        'id': 'sample_plot_b1',
        'layout_id': 'sample_layout_b',
        'layout_name': 'Layout B',
        'plot_number': 'B-201',
        'area': 1100.00,
        'all_in_cost_per_sqft': 2550.00,
        'status': 'pending',
        'sale_price': 3100.00,
        'agent_name': 'Karan Mehta',
        'partners': ['Bluefield Ventures'],
      },
      {
        'id': 'sample_plot_b2',
        'layout_id': 'sample_layout_b',
        'layout_name': 'Layout B',
        'plot_number': 'B-202',
        'area': 1150.00,
        'all_in_cost_per_sqft': 2550.00,
        'status': 'available',
        'sale_price': 0.00,
        'partners': ['Apex Holdings', 'Bluefield Ventures'],
      },
    ];
    const plotPartners = <Map<String, dynamic>>[
      {'plot_id': 'sample_plot_a1', 'partner_name': 'Apex Holdings'},
      {'plot_id': 'sample_plot_a2', 'partner_name': 'Bluefield Ventures'},
      {'plot_id': 'sample_plot_a3', 'partner_name': 'Apex Holdings'},
      {'plot_id': 'sample_plot_b1', 'partner_name': 'Bluefield Ventures'},
      {'plot_id': 'sample_plot_b2', 'partner_name': 'Apex Holdings'},
      {'plot_id': 'sample_plot_b2', 'partner_name': 'Bluefield Ventures'},
    ];

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
      'nonSellableArea': nonSellableArea.toStringAsFixed(2),
      'non_sellable_area': nonSellableArea,
      'amenityArea': amenityArea.toStringAsFixed(2),
      'amenity_area': amenityArea,
      'allInCost': allInCost.toStringAsFixed(2),
      'all_in_cost': allInCost,
      'estimatedDevelopmentCost': estimatedDevelopmentCost.toStringAsFixed(2),
      'estimated_development_cost': estimatedDevelopmentCost,
      'totalExpenses': totalExpenses.toStringAsFixed(2),
      'total_expenses': totalExpenses,
      'totalSalesValue': totalSalesValue.toStringAsFixed(2),
      'total_sales_value': totalSalesValue,
      'avgSalesPrice': avgSalesPrice.toStringAsFixed(2),
      'avg_sales_price': avgSalesPrice,
      'grossProfit': grossProfit.toStringAsFixed(2),
      'gross_profit': grossProfit,
      'netProfit': netProfit.toStringAsFixed(2),
      'net_profit': netProfit,
      'profitMargin': profitMargin.toStringAsFixed(2),
      'profit_margin': profitMargin,
      'roi': roi.toStringAsFixed(2),
      'totalPMCompensation': totalPMCompensation.toStringAsFixed(2),
      'total_pm_compensation': totalPMCompensation,
      'totalAgentCompensation': totalAgentCompensation.toStringAsFixed(2),
      'total_agent_compensation': totalAgentCompensation,
      'totalCompensation': totalCompensation.toStringAsFixed(2),
      'total_compensation': totalCompensation,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'hide_default_non_sellable_template': false,
      'hide_default_amenity_template': false,
      'totalLayouts': layouts.length,
      'totalPlots': plots.length,
      'soldPlots': 2,
      'availablePlots': 2,
      'pendingPlots': 1,
      'amenityLayoutImageName': '',
      'amenityLayoutImagePath': '',
      'amenityLayoutImageDocId': '',
      'amenityLayoutImageExtension': '',
      'partners': partners,
      'expenses': expenses,
      'nonSellableAreas': nonSellableAreas,
      'amenityAreas': amenityAreas,
      'plots': plots,
      'layouts': layouts,
      'project_managers': projectManagers,
      'agents': agents,
      'plot_partners': plotPartners,
      '_is_default_sample_project': true,
      '_read_only': true,
    };
  }
}
