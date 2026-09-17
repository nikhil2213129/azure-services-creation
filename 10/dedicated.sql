-- Create products table
CREATE TABLE dbo.products(
	ProductID INT NOT NULL,
	ProductName NVARCHAR (100) NOT NULL,
	Category NVARCHAR (100) NOT NULL,
	ListPrice DECIMAL NULL
);
GO

PRINT 'products table created.';
GO

-- Create customers table
CREATE TABLE dbo.customers(
	CustomerID INT NOT NULL,
	FirstName NVARCHAR (50) NOT NULL,
	LastName NVARCHAR (50) NOT NULL,
	Email NVARCHAR (100) NULL,
	City NVARCHAR (100) NULL
);
GO

PRINT 'customers table created.';
GO

-- Create orders table
CREATE TABLE dbo.orders(
	OrderID INT NOT NULL,
	CustomerID INT NOT NULL,
	ProductID INT NOT NULL,
	OrderDate DATE NOT NULL,
	Quantity INT NOT NULL
);
GO

PRINT 'orders table created.';
GO

-- Grant the service principal used by Purview read access to these tables
CREATE USER [SQLSERVICEPRINCIPALNAME] FROM EXTERNAL PROVIDER;
GO

ALTER ROLE db_datareader ADD MEMBER [SQLSERVICEPRINCIPALNAME];
GO

PRINT 'Service principal SQLSERVICEPRINCIPALNAME granted db_datareader.';
GO
