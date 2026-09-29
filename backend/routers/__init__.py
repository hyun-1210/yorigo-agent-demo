"""
API routers for Yorigo Backend

This package contains FastAPI routers for different API endpoints:
- health.py: Health check and monitoring endpoints
- product.py: Product search and recommendation endpoints
- ingredient.py: Ingredient preprocessing and categorization endpoints
- auth.py: Authentication endpoints (Kakao login)
"""

from .health import router as health_router
from .product import create_product_router
from .ingredient import create_ingredient_router
from .ingredient_price import create_ingredient_price_router
from .auth import router as auth_router
from .fridge import create_fridge_router
from .purchase_verification import create_purchase_verification_router
# 쿠팡 주문→계정 매칭은 비용 때문에 당분간 비활성. 되살릴 때 주석 해제.
# from .coupang_orders import create_coupang_orders_router
from .recipe_agent import create_recipe_agent_router
from .home_agent import create_home_agent_router
from .grocery_agent import create_grocery_agent_router

__all__ = [
    'health_router',
    'create_product_router',
    'create_ingredient_router',
    'create_ingredient_price_router',
    'auth_router',
    'create_fridge_router',
    'create_purchase_verification_router',
    # 'create_coupang_orders_router',
    'create_recipe_agent_router',
    'create_home_agent_router',
    'create_grocery_agent_router',
]

